#include "fitcache_comm.h"
#include "fitcache_cluster_registry.h"
#include "fitcache_cross_job.h"
#include "fitcache_data_mover_internal.h"
#include "fitcache_cache_policy.h"
#include "fitcache_logging.h"
#include "fitcache_timer.h"

#include <atomic>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <map>
#include <shared_mutex>
#include <string>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <thread>
#include <unordered_map>
#include <vector>

// External server ID variable declared in fitcache_server.cpp

// ============================================================
// Cross-job open-time peer-lookup fanout (cluster-scoped
// coordination protocol, peer-fanout fallback).
//
// On a path_cache_map miss with FitCache_CROSS_JOB=1, the open
// handler fans out fitcache_peer_lookup_rpc to every live peer
// (excluding self) in parallel. The first peer that responds
// has=1 wins; the open handler responds with
//   ret_status = FITCACHE_OPEN_REDIRECT
//   peer_addr  = <winner's Mercury addr>
// and the client re-issues the open against that peer's slot.
//
// If every peer says no (or the registry is empty), the handler
// falls through to PFS open + cache-promotion as before.
//
// The fanout is async — the handler returns without responding
// and the response is fired from the last (or first-yes) peer
// callback. This is to avoid blocking the Mercury progress
// thread waiting for peer responses, which would deadlock since
// the same thread drives those responses.
// ============================================================

// hg_id_t for fitcache_peer_lookup_rpc captured at server-side
// registration time so the open handler can issue HG_Forward.
static hg_id_t g_peer_lookup_id = 0;

hg_id_t fitcache_peer_lookup_get_id(void) {
    return g_peer_lookup_id;
}

// hg_id_t for fitcache_register_file_rpc — captured at registration time
// so the data-mover broadcast helper can find peers.
static hg_id_t g_register_file_id = 0;
static hg_id_t g_prefetch_id = 0;
static hg_id_t g_migrate_chunk_id = 0;

hg_id_t fitcache_register_file_get_id(void) {
    return g_register_file_id;
}

// ============================================================
// Cross-job has_yes=0 fix Option 2: thin C-side wrappers over the in-memory
// remote_presence_map. The state itself lives in
// src/cross_job/fitcache_cross_job.cpp (so the smoke test can link to it
// without Mercury); the Mercury-backed register-file RPC handler below
// writes into it via fitcache::remote_presence_insert.
// ============================================================

std::string fitcache_remote_presence_lookup(const std::string &path) {
    return fitcache::remote_presence_lookup(path);
}

size_t fitcache_remote_presence_count() {
    return fitcache::remote_presence_count();
}

void fitcache_remote_presence_clear_for_test() {
    fitcache::remote_presence_clear_for_test();
}

void fitcache_remote_presence_insert_for_test(const std::string &path,
                                              const std::string &addr) {
    fitcache::remote_presence_insert(path, addr);
}

// State carried across all peer_lookup callbacks for one in-flight open.
// refcount cleanup model:
//   start at 1 (issuer holds a ref)
//   bump by 1 per successful HG_Forward (callback drops it)
//   bump by 1 for the watchdog thread (watchdog drops it on exit)
//   release once on issuer's exit
struct OpenPeerLookupState {
    hg_handle_t                 open_handle;
    std::string                 original_path;
    std::atomic<int>            refcount;
    std::atomic<int>            responses_remaining;
    std::atomic<bool>           responded;
    pthread_mutex_t             respond_mtx;
    std::string                 peer_addr_winner;   // protected by respond_mtx
    // Watchdog support — see peer_lookup_watchdog_fn below.
    // pending_handles holds the hg_handle_t for each in-flight peer_lookup
    // forward. The callback removes its own entry under respond_mtx before
    // HG_Destroy; the watchdog iterates whatever's still in it after the
    // deadline elapses and HG_Cancel's them (forcing the callback to fire
    // with HG_CANCELED so our normal cleanup runs).
    std::vector<hg_handle_t>    pending_handles;
};

static void state_release(OpenPeerLookupState *st) {
    if (st->refcount.fetch_sub(1) == 1) {
        pthread_mutex_destroy(&st->respond_mtx);
        delete st;
    }
}

// Open the file from PFS as the original handler did, then respond.
// Caller must guarantee st->responded is now true (set under respond_mtx).
static void respond_open_pfs(OpenPeerLookupState *st) {
    fitcache::cross_job_counter_bump_opens_pfs_fallback();
    fitcache_open_out_t out;
    out.ret_status = open(st->original_path.c_str(), O_RDONLY);
    out.peer_addr  = const_cast<char*>("");
    L4C_INFO("Server Rank %d : Opened %s with fd %d (PFS fallback after peer fanout)",
             server_rank, st->original_path.c_str(), out.ret_status);
    if (out.ret_status == -1) {
        L4C_ERR("Failed to open file: %s", st->original_path.c_str());
        out.ret_status = -errno;
    } else {
        std::unique_lock<std::shared_mutex> wlock(cache_mtx);
        fd_to_path[out.ret_status] = st->original_path;
    }
    HG_Respond(st->open_handle, NULL, NULL, &out);
}

// Tell the client to retry the open against st->peer_addr_winner.
// Caller must guarantee st->responded is now true.
static void respond_open_redirect(OpenPeerLookupState *st) {
    fitcache::cross_job_counter_bump_opens_redirect_to_peer();
    fitcache_open_out_t out;
    out.ret_status = FITCACHE_OPEN_REDIRECT;
    out.peer_addr  = const_cast<char*>(st->peer_addr_winner.c_str());
    L4C_INFO("Server Rank %d : Open RPC redirect %s -> peer %s",
             server_rank, st->original_path.c_str(), st->peer_addr_winner.c_str());
    HG_Respond(st->open_handle, NULL, NULL, &out);
}

// Mercury callback fired when one peer's peer_lookup_rpc response arrives
// (or when the watchdog cancels the request).
static hg_return_t peer_lookup_response_cb(const struct hg_cb_info *info) {
    OpenPeerLookupState *st = (OpenPeerLookupState *)info->arg;
    hg_handle_t this_handle = info->info.forward.handle;
    fitcache_peer_lookup_out_t out;
    bool got_yes = false;
    std::string winner_addr;

    if (info->ret == HG_SUCCESS &&
        HG_Get_output(this_handle, &out) == HG_SUCCESS) {
        if (out.has == 1 && out.serve_addr != NULL && out.serve_addr[0] != '\0') {
            got_yes     = true;
            winner_addr = out.serve_addr;
        }
        HG_Free_output(this_handle, &out);
    }
    // info->ret == HG_CANCELED here means the watchdog gave up on this peer;
    // fall through to the not-yet-responded counters so the next branch
    // either picks another peer's yes or triggers PFS fallback.

    bool should_redirect = false;
    bool should_fallback = false;

    pthread_mutex_lock(&st->respond_mtx);
    // Remove our handle from pending_handles so the watchdog can no longer
    // touch it. Do this BEFORE HG_Destroy.
    for (auto it = st->pending_handles.begin(); it != st->pending_handles.end(); ++it) {
        if (*it == this_handle) {
            st->pending_handles.erase(it);
            break;
        }
    }
    int remaining = --st->responses_remaining;
    if (!st->responded.load() && got_yes) {
        st->peer_addr_winner = winner_addr;
        st->responded.store(true);
        should_redirect = true;
    } else if (!st->responded.load() && remaining == 0) {
        st->responded.store(true);
        should_fallback = true;
    }
    pthread_mutex_unlock(&st->respond_mtx);

    HG_Destroy(this_handle);

    if (should_redirect) respond_open_redirect(st);
    if (should_fallback) respond_open_pfs(st);

    state_release(st);
    return HG_SUCCESS;
}

// Watchdog thread for one in-flight peer-lookup fanout.
//
// Sleeps until the deadline (peer_rpc_timeout_sec after fanout). If the
// state has already responded by then (normal path), exits quietly. Otherwise,
// HG_Cancels every still-pending lookup_handle (forcing each callback to
// fire with HG_CANCELED, which drives our normal has_no path), and respond
// to the client with PFS-fallback right now so the client isn't blocked
// waiting for the cancellations to propagate.
//
// Holds one refcount on the state so the state survives until this thread
// exits, even if every callback fires + drops its ref first.
static void peer_lookup_watchdog_fn(OpenPeerLookupState *st, int timeout_sec) {
    std::this_thread::sleep_for(std::chrono::seconds(timeout_sec));

    bool we_responded = false;
    std::vector<hg_handle_t> to_cancel;

    pthread_mutex_lock(&st->respond_mtx);
    if (!st->responded.load() && !st->pending_handles.empty()) {
        st->responded.store(true);
        we_responded = true;
        // Snapshot pending handles to cancel; clear so the callbacks (which
        // will fire as HG_CANCELED) skip the cancellation step on their side.
        // The callbacks will still erase from pending_handles defensively;
        // we leave the vector populated so they find their entries and
        // HG_Destroy correctly. Don't clear here.
        to_cancel = st->pending_handles;
    }
    pthread_mutex_unlock(&st->respond_mtx);

    if (we_responded) {
        L4C_WARN("peer_lookup watchdog fired after %d sec on %s "
                 "(canceling %zu in-flight forwards, falling back to PFS)",
                 timeout_sec, st->original_path.c_str(), to_cancel.size());
        fitcache::cross_job_counter_bump_peer_lookup_timeout();
        // PFS open + HG_Respond to the client first — don't make the client
        // wait for Mercury to deliver the cancellation events.
        respond_open_pfs(st);
        // Cancel outstanding forwards. HG_Cancel is async; the callbacks
        // will fire with HG_CANCELED and clean up their own handles.
        for (hg_handle_t h : to_cancel) {
            (void)HG_Cancel(h);
        }
    }

    state_release(st);
}

hg_return_t
fitcache_open_rpc_handler(hg_handle_t handle)
{
    fitcache_open_in_t in;
    int ret = HG_Get_input(handle, &in);
    assert(ret == 0);

    std::string path_str = in.path;     // copy out before freeing input
    HG_Free_input(handle, &in);

    fitcache::cross_job_counter_bump_opens_total();
    L4C_INFO("Open RPC: requested path %s", path_str.c_str());

    // 1. Local cache hit?
    bool local_hit = false;
    std::string redir_path;
    {
        std::shared_lock<std::shared_mutex> rlock(cache_mtx);
        auto it = path_cache_map.find(path_str);
        if (it != path_cache_map.end()) {
            local_hit = true;
            redir_path = it->second;
        }
    }

    if (local_hit) {
        fitcache::cross_job_counter_bump_opens_local_hit();
        L4C_INFO("Server Rank %d : Successful Redirection %s to %s",
                 server_rank, path_str.c_str(), redir_path.c_str());
        fitcache_open_out_t out;
        out.ret_status = open(redir_path.c_str(), O_RDONLY);
        out.peer_addr  = const_cast<char*>("");
        L4C_INFO("Server Rank %d : Opened %s with fd %d",
                 server_rank, redir_path.c_str(), out.ret_status);
        if (out.ret_status == -1) {
            L4C_ERR("Failed to open file: %s", redir_path.c_str());
            out.ret_status = -errno;
        } else {
            std::unique_lock<std::shared_mutex> wlock(cache_mtx);
            fd_to_path[out.ret_status] = path_str;
        }
        HG_Respond(handle, NULL, NULL, &out);
        return (hg_return_t)ret;
    }

    // 2. Cross-job mode: fan out peer-lookup queries to live peers.
    if (fitcache::cross_job_enabled() && g_peer_lookup_id != 0) {
        const std::string &my_addr = fitcache_comm_get_self_addr_string();
        std::vector<fitcache::ServerEndpoint> live = fitcache::registry_live_servers();

        std::vector<fitcache::ServerEndpoint> peers;
        for (const auto &s : live) {
            if (s.live && !s.addr.empty() && s.addr != my_addr) {
                peers.push_back(s);
            }
        }

        if (!peers.empty()) {
            auto *st = new OpenPeerLookupState();
            st->open_handle         = handle;
            st->original_path       = path_str;
            st->refcount.store(1);  // issuer holds a ref
            st->responses_remaining.store(static_cast<int>(peers.size()));
            st->responded.store(false);
            pthread_mutex_init(&st->respond_mtx, NULL);

            int forwards_issued = 0;
            for (const auto &peer : peers) {
                hg_addr_t peer_hg_addr = NULL;
                if (HG_Addr_lookup2(hg_class, peer.addr.c_str(), &peer_hg_addr) != HG_SUCCESS
                    || peer_hg_addr == NULL) {
                    --st->responses_remaining;
                    continue;
                }
                hg_handle_t lookup_handle = NULL;
                if (HG_Create(hg_context, peer_hg_addr, g_peer_lookup_id, &lookup_handle) != HG_SUCCESS) {
                    HG_Addr_free(hg_class, peer_hg_addr);
                    --st->responses_remaining;
                    continue;
                }
                fitcache_peer_lookup_in_t lookup_in;
                lookup_in.path                  = const_cast<char*>(path_str.c_str());
                lookup_in.dataset_root_hash     = 0;  // TODO: dataset_id wiring
                lookup_in.dataset_manifest_hash = 0;

                st->refcount.fetch_add(1);  // hold a ref for the in-flight callback
                // Add to pending_handles BEFORE HG_Forward so the watchdog
                // can never see a forwarded-but-untracked handle.
                pthread_mutex_lock(&st->respond_mtx);
                st->pending_handles.push_back(lookup_handle);
                pthread_mutex_unlock(&st->respond_mtx);
                hg_return_t hr = HG_Forward(lookup_handle, peer_lookup_response_cb, st, &lookup_in);
                HG_Addr_free(hg_class, peer_hg_addr);
                if (hr != HG_SUCCESS) {
                    // Pull the handle back out — it never went out.
                    pthread_mutex_lock(&st->respond_mtx);
                    for (auto it = st->pending_handles.begin(); it != st->pending_handles.end(); ++it) {
                        if (*it == lookup_handle) { st->pending_handles.erase(it); break; }
                    }
                    pthread_mutex_unlock(&st->respond_mtx);
                    HG_Destroy(lookup_handle);
                    state_release(st);          // give back the ref we just bumped
                    --st->responses_remaining;
                    continue;
                }
                fitcache::cross_job_counter_bump_peer_lookup_forwarded();
                ++forwards_issued;
            }

            // If every forward failed (responses_remaining hit 0 in the loop) we have
            // to do the PFS fallback ourselves; no callbacks will fire.
            bool should_fallback_now = false;
            pthread_mutex_lock(&st->respond_mtx);
            if (!st->responded.load() && st->responses_remaining.load() == 0) {
                st->responded.store(true);
                should_fallback_now = true;
            }
            pthread_mutex_unlock(&st->respond_mtx);

            if (should_fallback_now) {
                respond_open_pfs(st);
            }

            // Arm the per-fanout watchdog, but only if at least one forward
            // actually flew and the deadline is positive (timeout=0 disables).
            int timeout_sec = fitcache::peer_rpc_timeout_sec();
            if (forwards_issued > 0 && timeout_sec > 0 && !should_fallback_now) {
                st->refcount.fetch_add(1);  // hold a ref for the watchdog
                std::thread(peer_lookup_watchdog_fn, st, timeout_sec).detach();
            }

            state_release(st);  // drop the issuer ref; callbacks (if any) keep their own
            (void)forwards_issued;
            return (hg_return_t)ret;  // do NOT respond inline
        }
    }

    // 3. PFS fallback (existing single-job behaviour).
    fitcache::cross_job_counter_bump_opens_pfs_fallback();
    fitcache_open_out_t out;
    out.ret_status = open(path_str.c_str(), O_RDONLY);
    out.peer_addr  = const_cast<char*>("");
    L4C_INFO("Server Rank %d : Opened %s with fd %d", server_rank, path_str.c_str(), out.ret_status);
    if (out.ret_status == -1) {
        L4C_ERR("Failed to open file: %s", path_str.c_str());
        out.ret_status = -errno;
    } else {
        bool need_promote = false;
        {
            std::unique_lock<std::shared_mutex> wlock(cache_mtx);
            fd_to_path[out.ret_status] = path_str;
            need_promote = (path_cache_map.find(path_str) == path_cache_map.end());
        }
        // Promote at OPEN time (not only at close). Under the mmap/fd-reuse
        // access pattern (numpy.memmap reuses the same fd per shard), the
        // client's open_cb response is dropped as stale by the epoch guard,
        // leaving fd_redir_map[fd]==0, which makes the client skip the close
        // RPC — so close-time promotion never fires and the cache stays empty
        // (the cache that the warm-hit direct-mmap path needs). Enqueueing at
        // open time guarantees promotion regardless of the close RPC. The data
        // mover dedups against path_cache_map, so a double enqueue is harmless.
        if (need_promote) {
            L4C_INFO("Open-time promote enqueue: %s", path_str.c_str());
            pthread_mutex_lock(&data_mutex);
            data_queue.push(path_str);
            pthread_cond_signal(&data_cond);
            pthread_mutex_unlock(&data_mutex);
        }
    }
    HG_Respond(handle, NULL, NULL, &out);
    return (hg_return_t)ret;
}


// * handle read request
hg_return_t
fitcache_rpc_handler(hg_handle_t handle)
{
    int ret;
    struct fitcache_rpc_state *fitcache_rpc_state_p;
    const struct hg_info *hgi;
    ssize_t readbytes;
    fitcache_rpc_state_p = (struct fitcache_rpc_state*)malloc(sizeof(*fitcache_rpc_state_p));

    /* decode input */
    HG_Get_input(handle, &fitcache_rpc_state_p->in);   
    
    /* This includes allocating a target buffer for bulk transfer */
    fitcache_rpc_state_p->buffer = calloc(1, fitcache_rpc_state_p->in.input_val);
    assert(fitcache_rpc_state_p->buffer);

    fitcache_rpc_state_p->size = fitcache_rpc_state_p->in.input_val;
    fitcache_rpc_state_p->handle = handle;

    /* register local target buffer for bulk access */
    hgi = HG_Get_info(handle);
    assert(hgi);
    ret = HG_Bulk_create(hgi->hg_class, 1, &fitcache_rpc_state_p->buffer,
        &fitcache_rpc_state_p->size, HG_BULK_READ_ONLY,
        &fitcache_rpc_state_p->bulk_handle);
    assert(ret == 0);

    // Loop the read/pread until the full requested size is satisfied. A single
    // Linux read()/pread() is silently capped by the kernel at 0x7ffff000
    // (2,147,479,552 bytes ~= 2 GiB), returning a short count. The previous
    // single-call code left the tail of any request > ~2 GiB zero-filled,
    // which silently truncated large mmap eager-populates (Megatron 16 GiB
    // shards, IGB-large 9.8 GiB CSR). Loop on the short count to read the rest.
    {
        char *buf = (char *) fitcache_rpc_state_p->buffer;
        size_t want = (size_t) fitcache_rpc_state_p->size;
        size_t got = 0;
        bool use_pread = (fitcache_rpc_state_p->in.offset != -1);
        int rfd = fitcache_rpc_state_p->in.accessfd;
        int64_t base_off = fitcache_rpc_state_p->in.offset;
        readbytes = 0;
        while (got < want) {
            ssize_t n;
            if (use_pread) {
                n = pread(rfd, buf + got, want - got, base_off + (int64_t) got);
            } else {
                n = read(rfd, buf + got, want - got);
            }
            if (n < 0) {
                if (errno == EINTR) continue;
                if (got == 0) { readbytes = -1; }
                break;          // hard error; return what we have
            }
            if (n == 0) break;  // EOF (request extended past end of file)
            got += (size_t) n;
        }
        if (readbytes != -1) readbytes = (ssize_t) got;
        if(DEBUG_HU)
        {
            std::string path_copy;
            {
                std::shared_lock<std::shared_mutex> rlock(cache_mtx);
                auto it = fd_to_path.find(rfd);
                if (it != fd_to_path.end()) path_copy = it->second;
            }
            L4C_DEBUG("Server Rank %d : %s %ld bytes from file %s (offset %lld)",
                      server_rank, use_pread ? "PRead" : "Read", (long) readbytes,
                      path_copy.c_str(), (long long) base_off);
        }
    }

    //Reduce size of transfer to what was actually read 
    //We may need to revisit this.
    fitcache_rpc_state_p->size = readbytes;

    /* initiate bulk transfer from client to server */
    ret = HG_Bulk_transfer(hgi->context, fitcache_rpc_handler_bulk_cb, fitcache_rpc_state_p,
        HG_BULK_PUSH, hgi->addr, fitcache_rpc_state_p->in.bulk_handle, 0,
        fitcache_rpc_state_p->bulk_handle, 0, fitcache_rpc_state_p->size, HG_OP_ID_IGNORE);
    
    assert(ret == 0);
    (void) ret;

    return (hg_return_t)ret;
}

static hg_return_t
fitcache_close_rpc_handler(hg_handle_t handle)
{
    fitcache_close_in_t in;
    int ret = HG_Get_input(handle, &in);
    assert(ret == HG_SUCCESS);
    L4C_INFO("DEBUG HU: Closing File %d\n",in.fd);
    ret = close(in.fd);
    if(ret != 0) {
        L4C_ERR("Failed to close file %d, errno: %d (%s)", in.fd, errno, strerror(errno));
    }

    if (path_cache_map.find(fd_to_path[in.fd]) == path_cache_map.end())
    {
        L4C_INFO("Caching %s",fd_to_path[in.fd].c_str());
        pthread_mutex_lock(&data_mutex);
        data_queue.push(fd_to_path[in.fd]);
        pthread_cond_signal(&data_cond);
        pthread_mutex_unlock(&data_mutex);
    }   

    fd_to_path.erase(in.fd);
 
    return (hg_return_t)ret;
}

static hg_return_t
fitcache_seek_rpc_handler(hg_handle_t handle)
{
    fitcache_seek_in_t in;
    fitcache_seek_out_t out;    
    int ret = HG_Get_input(handle, &in);
    assert(ret == 0);

    out.ret = lseek64(in.fd, in.offset, in.whence);

    HG_Respond(handle,NULL,NULL,&out);

    return (hg_return_t)ret;
}

/* register this particular rpc type with Mercury */
hg_id_t
fitcache_rpc_register_server(void)
{
    hg_id_t tmp;
    // & replace HG_Register()
    tmp = MERCURY_REGISTER(
        hg_class, "fitcache_base_rpc", fitcache_rpc_in_t, fitcache_rpc_out_t, fitcache_rpc_handler);

    return tmp;
}

hg_id_t
fitcache_open_rpc_register_server(void)
{
    hg_id_t tmp;

    tmp = MERCURY_REGISTER(
        hg_class, "fitcache_open_rpc", fitcache_open_in_t, fitcache_open_out_t, fitcache_open_rpc_handler);

    return tmp;
}

hg_id_t
fitcache_close_rpc_register_server(void)
{
    hg_id_t tmp;

    tmp = MERCURY_REGISTER(
        hg_class, "fitcache_close_rpc", fitcache_close_in_t, void, fitcache_close_rpc_handler);
    

    int ret =  HG_Registered_disable_response(hg_class, tmp,HG_TRUE);                        
    assert(ret == HG_SUCCESS);

    return tmp;
}

/* register this particular rpc type with Mercury */
hg_id_t
fitcache_seek_rpc_register_server(void)
{
    hg_id_t tmp;

    tmp = MERCURY_REGISTER(
        hg_class, "fitcache_seek_rpc", fitcache_seek_in_t, fitcache_seek_out_t, fitcache_seek_rpc_handler);

    return tmp;
}

// RPC handler for printing server statistics
hg_return_t
fitcache_trigger_srv_print_stats_rpc_handler(hg_handle_t handle)
{
    FitCache_TIMING("HvacServer_print_stats_rpc_handler_Total");
    
    fitcache_rpc_trigger_srv_print_stats_in_t in;
    fitcache_rpc_trigger_srv_print_stats_out_t out;
    
    int ret = HG_Get_input(handle, &in);
    assert(ret == HG_SUCCESS);

    L4C_INFO("Received RPC request to print timer statistics...");

    // Print statistics to console
    fitcache::print_all_stats();
    
    // Export to file with timestamp
    char filename[256];
    time_t now = time(0);
    struct tm* timeinfo = localtime(&now);
    snprintf(filename, sizeof(filename), "fitcache_server_stats_%04d%02d%02d_%02d%02d%02d.csv",
            timeinfo->tm_year + 1900, timeinfo->tm_mon + 1, timeinfo->tm_mday,
            timeinfo->tm_hour, timeinfo->tm_min, timeinfo->tm_sec);
    
    fitcache::export_all_stats_to_file(filename);
    L4C_INFO("Timer statistics exported to %s", filename);

    // Send success response
    out.status = 0;  // 0 indicates success

    HG_Respond(handle, NULL, NULL, &out);

    return HG_SUCCESS;
}

// Register RPC for triggering server to print stats
hg_id_t
fitcache_trigger_srv_print_stats_rpc_register(void)
{
    hg_id_t tmp;

    tmp = MERCURY_REGISTER(
        hg_class, "fitcache_trigger_srv_print_stats_rpc", 
        fitcache_rpc_trigger_srv_print_stats_in_t, 
        fitcache_rpc_trigger_srv_print_stats_out_t, 
        fitcache_trigger_srv_print_stats_rpc_handler);

    return tmp;
}

// Universal RPC registration functions
hg_id_t fitcache_rpc_register(void) {
    return fitcache_rpc_register_server();
}

hg_id_t fitcache_open_rpc_register(void) {
    return fitcache_open_rpc_register_server();
}

hg_id_t fitcache_close_rpc_register(void) {
    return fitcache_close_rpc_register_server();
}

hg_id_t fitcache_seek_rpc_register(void) {
    return fitcache_seek_rpc_register_server();
}

// ============================================================
// Cross-job peer-lookup RPC. Part of the cluster-scoped
// coordination protocol described in
// tpds_extension/02_design_cross_job.md.
// ------------------------------------------------------------
// Real handler: consults path_cache_map under cache_mtx and, if
// the requested path is cached locally, responds with
//   has = 1
//   tier = CACHE_TIER_DRAM (per-file tier tracking deferred to
//          the sidecar-metadata work)
//   serve_addr = this server's own Mercury addr
// otherwise responds has = 0.
//
// Dataset-identity verification (root_path_hash + manifest_hash
// match) is intentionally deferred to the sidecar-metadata work,
// which is when the server will track its own dataset_id. The
// path-level match is conservative for the open-time peer-lookup
// fanout work: the same path
// implies the same dataset path, which is the dominant correctness
// case for the bit-for-bit DL training scenario.
// ============================================================
hg_return_t
fitcache_peer_lookup_rpc_handler(hg_handle_t handle)
{
    fitcache_peer_lookup_in_t  in;
    fitcache_peer_lookup_out_t out;
    int ret = HG_Get_input(handle, &in);
    assert(ret == HG_SUCCESS);

    fitcache::cross_job_counter_bump_peer_lookup_handled();

    // Source-of-truth resolution order (cross-job has_yes=0 fix):
    //   1. local path_cache_map  — fastest, in-memory, this server cached it.
    //   2. remote_presence_map   — fastest cluster-wide path (Option 2 RPC).
    //   3. PFS presence index    — durable cluster-wide path (Option 1).
    //
    // Steps 2+3 let us answer has=1 with a remote serve_addr even if THIS
    // server never cached the file — closing the prior gap where peer_lookup
    // fan-out hit a peer that hadn't seen the path, returned has=0, and the
    // client fell through to PFS even though some other peer had it cached.

    // Step 1: local cache hit?
    bool local_found = false;
    {
        std::shared_lock<std::shared_mutex> rlock(cache_mtx);
        auto it = path_cache_map.find(in.path);
        local_found = (it != path_cache_map.end());
    }
    const std::string &my_addr = fitcache_comm_get_self_addr_string();

    if (local_found) {
        fitcache::cross_job_counter_bump_peer_lookup_has_yes();
        out.has        = 1;
        out.tier       = (int32_t)CACHE_TIER_DRAM;
        out.serve_addr = const_cast<char *>(my_addr.c_str());
        L4C_INFO("peer_lookup: rank=%d path=%s -> HAS local (serve_addr=%s)",
                 server_rank, in.path, my_addr.c_str());
        HG_Respond(handle, NULL, NULL, &out);
        HG_Free_input(handle, &in);
        HG_Destroy(handle);
        return (hg_return_t)ret;
    }

    // Step 2: remote presence (Option 2 — in-memory map populated by inbound
    // register-file RPCs from peers).
    std::string remote_addr = fitcache_remote_presence_lookup(in.path);

    // Step 3: PFS presence index (Option 1 — durable). Read only if step 2
    // came up empty, to avoid an unnecessary PFS read on the hot path. The
    // returned list may include this server's own addr — filter that out
    // (we already know we don't have it locally, so a stale self-entry
    // would be a false positive).
    if (remote_addr.empty()) {
        auto holders = fitcache::registry_lookup_file_presence(in.path);
        for (const auto &h : holders) {
            if (!h.addr.empty() && h.addr != my_addr) {
                remote_addr = h.addr;
                break;
            }
        }
    }

    if (!remote_addr.empty()) {
        fitcache::cross_job_counter_bump_peer_lookup_has_yes();
        out.has        = 1;
        out.tier       = (int32_t)CACHE_TIER_DRAM;
        out.serve_addr = const_cast<char *>(remote_addr.c_str());
        L4C_INFO("peer_lookup: rank=%d path=%s -> HAS remote (serve_addr=%s)",
                 server_rank, in.path, remote_addr.c_str());
        HG_Respond(handle, NULL, NULL, &out);
        HG_Free_input(handle, &in);
        HG_Destroy(handle);
        return (hg_return_t)ret;
    }

    fitcache::cross_job_counter_bump_peer_lookup_has_no();
    out.has        = 0;
    out.tier       = 0;
    out.serve_addr = const_cast<char *>("");
    L4C_INFO("peer_lookup: rank=%d path=%s -> NOT HAS",
             server_rank, in.path);
    (void)in.dataset_root_hash;       // TODO: dataset_id verification
    (void)in.dataset_manifest_hash;   // ditto

    HG_Respond(handle, NULL, NULL, &out);
    HG_Free_input(handle, &in);
    HG_Destroy(handle);
    return (hg_return_t)ret;
}

hg_id_t
fitcache_peer_lookup_rpc_register_server(void)
{
    hg_id_t tmp = MERCURY_REGISTER(
        hg_class, "fitcache_peer_lookup_rpc",
        fitcache_peer_lookup_in_t, fitcache_peer_lookup_out_t,
        fitcache_peer_lookup_rpc_handler);
    g_peer_lookup_id = tmp;
    return tmp;
}

// ============================================================
// Cross-job register-file RPC handler (Option 2 incoming).
// Records (path -> serve_addr) in this server's remote_presence_map.
// Reply is fire-and-forget — we still HG_Respond so the sender's callback
// fires and the handle is released, but the sender doesn't act on the
// response.
// ============================================================
static hg_return_t
fitcache_register_file_rpc_handler(hg_handle_t handle)
{
    fitcache_register_file_in_t  in;
    fitcache_register_file_out_t out;
    int ret = HG_Get_input(handle, &in);
    assert(ret == HG_SUCCESS);

    std::string path = (in.path && in.path[0]) ? in.path : std::string();
    std::string addr = (in.serve_addr && in.serve_addr[0]) ? in.serve_addr : std::string();

    if (!path.empty() && !addr.empty()) {
        // Overwrite is the right semantic: the most recent register-file RPC
        // wins for any given path. If two servers race to register the same
        // path, the loser is harmless (a subsequent peer_lookup will land on
        // one of them, the client gets redirected, and the cache hits).
        fitcache::remote_presence_insert(path, addr);
    }
    L4C_INFO("register_file: rank=%d path=%s serve_addr=%s -> recorded",
             server_rank, path.c_str(), addr.c_str());
    (void)in.dataset_manifest_hash;

    out.status = 0;
    HG_Respond(handle, NULL, NULL, &out);
    HG_Free_input(handle, &in);
    HG_Destroy(handle);
    return (hg_return_t)ret;
}

hg_id_t
fitcache_register_file_rpc_register_server(void)
{
    hg_id_t tmp = MERCURY_REGISTER(
        hg_class, "fitcache_register_file_rpc",
        fitcache_register_file_in_t, fitcache_register_file_out_t,
        fitcache_register_file_rpc_handler);
    g_register_file_id = tmp;
    return tmp;
}

// Outbound broadcast: send a register_file_rpc to every other live peer
// in the cluster registry. The Mercury forward is async and fire-and-forget
// from our point of view — the response callback drops the handle and
// frees its output. We don't block on completion (the data_mover wants to
// return to its next promotion as soon as possible).
namespace {

// Callback for outbound register-file RPC: free the response, destroy the
// handle, drop our refcount. Nothing else to do — the sender is
// fire-and-forget.
hg_return_t register_file_forward_cb(const struct hg_cb_info *info) {
    hg_handle_t h = info->info.forward.handle;
    if (info->ret == HG_SUCCESS) {
        fitcache_register_file_out_t out;
        if (HG_Get_output(h, &out) == HG_SUCCESS) {
            HG_Free_output(h, &out);
        }
    }
    HG_Destroy(h);
    return HG_SUCCESS;
}

}  // namespace

void fitcache_broadcast_register_file(const std::string &path) {
    if (!fitcache::cross_job_enabled()) return;
    if (g_register_file_id == 0) return;
    if (path.empty()) return;

    const std::string &my_addr = fitcache_comm_get_self_addr_string();
    if (my_addr.empty()) return;

    std::vector<fitcache::ServerEndpoint> live = fitcache::registry_live_servers();
    if (live.empty()) return;

    fitcache_register_file_in_t in;
    in.path                   = const_cast<char *>(path.c_str());
    in.serve_addr             = const_cast<char *>(my_addr.c_str());
    in.dataset_manifest_hash  = fitcache::get_self_dataset_manifest_hash();

    int forwarded = 0;
    for (const auto &peer : live) {
        if (!peer.live || peer.addr.empty() || peer.addr == my_addr) continue;
        hg_addr_t peer_hg = NULL;
        if (HG_Addr_lookup2(hg_class, peer.addr.c_str(), &peer_hg) != HG_SUCCESS
            || peer_hg == NULL) continue;
        hg_handle_t h = NULL;
        if (HG_Create(hg_context, peer_hg, g_register_file_id, &h) != HG_SUCCESS) {
            HG_Addr_free(hg_class, peer_hg);
            continue;
        }
        hg_return_t hr = HG_Forward(h, register_file_forward_cb, NULL, &in);
        HG_Addr_free(hg_class, peer_hg);
        if (hr != HG_SUCCESS) {
            HG_Destroy(h);
            continue;
        }
        ++forwarded;
    }
    if (forwarded > 0) {
        L4C_INFO("register_file: rank=%d broadcast %s to %d peers",
                 server_rank, path.c_str(), forwarded);
    }
}

// ============================================================
// Prefetch RPC handler (TPDS prefetch-informed migration).
// The client forwards a prefetch hint for `path`; if the file is already
// cached locally we answer HIT, otherwise we enqueue it for the data mover
// (the same promotion path the open handler uses) and answer QUEUED. The
// promotion runs asynchronously so the call returns immediately and the app
// can overlap the prefetch with compute. replication_mode is forwarded for
// the limited-replication policy; the data mover / eviction policy consume it
// (no behavior change while it is the default UNBOUNDED=0).
// ============================================================
hg_return_t
fitcache_prefetch_rpc_handler(hg_handle_t handle)
{
    fitcache_prefetch_in_t in;
    int ret = HG_Get_input(handle, &in);
    assert(ret == HG_SUCCESS);

    std::string path_str = (in.path && in.path[0]) ? in.path : std::string();
    int mode = in.replication_mode;
    (void)in.target_slot; (void)in.replication_cap; (void)in.dataset_hash;
    HG_Free_input(handle, &in);

    fitcache_prefetch_out_t out;
    out.tier = 0;

    bool local_hit = false;
    if (!path_str.empty()) {
        std::shared_lock<std::shared_mutex> rlock(cache_mtx);
        local_hit = (path_cache_map.find(path_str) != path_cache_map.end());
    }

    if (path_str.empty()) {
        out.status = FITCACHE_PREFETCH_ERR;
    } else if (local_hit) {
        out.status = FITCACHE_PREFETCH_HIT;
    } else {
        L4C_INFO("Prefetch enqueue: %s (replication_mode=%d)", path_str.c_str(), mode);
        pthread_mutex_lock(&data_mutex);
        data_queue.push(path_str);
        pthread_cond_signal(&data_cond);
        pthread_mutex_unlock(&data_mutex);
        out.status = FITCACHE_PREFETCH_QUEUED;
    }

    HG_Respond(handle, NULL, NULL, &out);
    HG_Destroy(handle);
    return (hg_return_t)ret;
}

hg_id_t
fitcache_prefetch_rpc_register_server(void)
{
    hg_id_t tmp = MERCURY_REGISTER(
        hg_class, "fitcache_prefetch_rpc",
        fitcache_prefetch_in_t, fitcache_prefetch_out_t,
        fitcache_prefetch_rpc_handler);
    g_prefetch_id = tmp;
    return tmp;
}

hg_id_t
fitcache_prefetch_get_id(void)
{
    return g_prefetch_id;
}

// ============================================================
// Peer-migrate chunk RPC (TPDS migration primitive). Runs on the SOURCE server.
// The TARGET asked us to push [offset, len) of a cached file into its receive
// buffer (in.bulk_handle). We read the chunk synchronously, then HG_Bulk_PUSH
// it into the target's bulk handle; the bulk callback answers with the byte
// count and frees everything. Mirrors the read-bulk path (fitcache_rpc_handler).
// ============================================================
struct MigrateChunkServeState {
    hg_handle_t handle;
    void       *buffer;
    hg_size_t   size;          // bytes actually read (to transfer)
    hg_bulk_t   local_bulk;    // bulk over `buffer`
    fitcache_migrate_chunk_in_t in;  // kept alive (incl. origin bulk) until the cb
};

static hg_return_t
fitcache_migrate_chunk_bulk_cb(const struct hg_cb_info *info)
{
    MigrateChunkServeState *st = (MigrateChunkServeState *)info->arg;
    fitcache_migrate_chunk_out_t out;
    out.ret = (info->ret == HG_SUCCESS) ? (int64_t)st->size : -1;
    HG_Respond(st->handle, NULL, NULL, &out);
    HG_Bulk_free(st->local_bulk);
    HG_Free_input(st->handle, &st->in);
    HG_Destroy(st->handle);
    free(st->buffer);
    delete st;
    return HG_SUCCESS;
}

hg_return_t
fitcache_migrate_chunk_rpc_handler(hg_handle_t handle)
{
    MigrateChunkServeState *st = new MigrateChunkServeState();
    st->handle     = handle;
    st->buffer     = NULL;
    st->local_bulk = HG_BULK_NULL;
    st->size       = 0;
    int ret = HG_Get_input(handle, &st->in);
    assert(ret == HG_SUCCESS);

    std::string path = (st->in.path && st->in.path[0]) ? st->in.path : std::string();
    int64_t offset   = st->in.offset;
    int64_t len      = st->in.len;

    // Common failure exit: answer -1 and free everything.
    auto fail = [&]() {
        fitcache_migrate_chunk_out_t out; out.ret = -1;
        HG_Respond(handle, NULL, NULL, &out);
        HG_Free_input(handle, &st->in);
        HG_Destroy(handle);
        if (st->buffer) free(st->buffer);
        delete st;
    };

    if (path.empty() || len <= 0) { fail(); return (hg_return_t)ret; }

    std::string cached;
    {
        std::shared_lock<std::shared_mutex> rlock(cache_mtx);
        auto it = path_cache_map.find(path);
        if (it != path_cache_map.end()) cached = it->second;
    }
    if (cached.empty()) { fail(); return (hg_return_t)ret; }   // not ours -> target falls back

    int fd = open(cached.c_str(), O_RDONLY);
    if (fd < 0) { fail(); return (hg_return_t)ret; }

    st->buffer = malloc((size_t)len);
    if (!st->buffer) { close(fd); fail(); return (hg_return_t)ret; }

    // Read [offset, offset+len), looping on short pread.
    char *buf = (char *)st->buffer;
    size_t want = (size_t)len, got = 0;
    bool herr = false;
    while (got < want) {
        ssize_t n = pread(fd, buf + got, want - got, offset + (int64_t)got);
        if (n < 0) { if (errno == EINTR) continue; herr = true; break; }
        if (n == 0) break;   // EOF
        got += (size_t)n;
    }
    close(fd);
    if (herr && got == 0) { fail(); return (hg_return_t)ret; }
    st->size = (hg_size_t)got;

    const struct hg_info *hgi = HG_Get_info(handle);
    ret = HG_Bulk_create(hgi->hg_class, 1, &st->buffer, &st->size,
                         HG_BULK_READ_ONLY, &st->local_bulk);
    if (ret != 0) {                       // resource exhaustion etc. -> fail gracefully
        st->local_bulk = HG_BULK_NULL;
        L4C_ERR("migrate serve: HG_Bulk_create failed (%d)", ret);
        fail();
        return (hg_return_t)ret;
    }
    // PUSH source buffer -> target's receive bulk (origin).
    ret = HG_Bulk_transfer(hgi->context, fitcache_migrate_chunk_bulk_cb, st,
                           HG_BULK_PUSH, hgi->addr, st->in.bulk_handle, 0,
                           st->local_bulk, 0, st->size, HG_OP_ID_IGNORE);
    if (ret != 0) {                       // transfer setup failed; cb won't fire
        L4C_ERR("migrate serve: HG_Bulk_transfer failed (%d)", ret);
        HG_Bulk_free(st->local_bulk);
        st->local_bulk = HG_BULK_NULL;
        fail();
        return (hg_return_t)ret;
    }
    return (hg_return_t)ret;
}

hg_id_t
fitcache_migrate_chunk_rpc_register_server(void)
{
    hg_id_t tmp = MERCURY_REGISTER(
        hg_class, "fitcache_migrate_chunk_rpc",
        fitcache_migrate_chunk_in_t, fitcache_migrate_chunk_out_t,
        fitcache_migrate_chunk_rpc_handler);
    g_migrate_chunk_id = tmp;
    return tmp;
}

hg_id_t
fitcache_migrate_chunk_get_id(void)
{
    return g_migrate_chunk_id;
}

// ----- Target-side blocking single-chunk pull -----
// Refcounted state so the forward callback can safely fire even after the
// data-mover thread has timed out and moved on. The LAST of {callback, waiter}
// to release tears down the Mercury handle/bulk/addr and frees the state.
// notify is done UNDER the lock so the woken waiter cannot destroy the cv
// mid-notify (the classic "cv destroyed by woken thread" race).
namespace {
struct MigratePullState {
    std::mutex              m;
    std::condition_variable cv;
    bool                    done = false;
    int64_t                 ret  = -1;
    std::atomic<int>        refs{2};        // waiter + callback
    hg_handle_t             handle     = NULL;
    hg_bulk_t               local_bulk = HG_BULK_NULL;
    hg_addr_t               addr       = NULL;
};

void migrate_pull_release(MigratePullState *st)
{
    if (st->refs.fetch_sub(1) == 1) {       // last out frees everything
        if (st->local_bulk != HG_BULK_NULL) HG_Bulk_free(st->local_bulk);
        if (st->handle) HG_Destroy(st->handle);
        if (st->addr)   HG_Addr_free(hg_class, st->addr);
        delete st;
    }
}

hg_return_t fitcache_migrate_pull_cb(const struct hg_cb_info *info)
{
    MigratePullState *st = (MigratePullState *)info->arg;
    int64_t r = -1;
    if (info->ret == HG_SUCCESS) {
        fitcache_migrate_chunk_out_t out;
        if (HG_Get_output(info->info.forward.handle, &out) == HG_SUCCESS) {
            r = out.ret;
            HG_Free_output(info->info.forward.handle, &out);
        }
    }
    {
        std::lock_guard<std::mutex> lk(st->m);
        st->ret  = r;
        st->done = true;
        st->cv.notify_one();                // notify under the lock (destruction-safe)
    }
    migrate_pull_release(st);
    return HG_SUCCESS;
}

// Per-chunk timeout (seconds). A 1 GiB chunk over the fabric is seconds; a dead
// peer must not wedge the data mover, so we cap the wait and HG_Cancel.
int migrate_pull_timeout_sec()
{
    const char *e = getenv("FitCache_MIGRATE_TIMEOUT_SEC");
    int v = e ? atoi(e) : 0;
    return (v > 0) ? v : 300;
}
}  // namespace

int64_t
fitcache_comm_migrate_pull_chunk(const std::string &src_addr, const std::string &path,
                                 int64_t offset, int64_t len, void *buf, size_t buf_cap)
{
    if (len <= 0 || (size_t)len > buf_cap || buf == NULL) return -1;

    hg_addr_t addr = NULL;
    if (HG_Addr_lookup2(hg_class, src_addr.c_str(), &addr) != HG_SUCCESS || addr == NULL) {
        L4C_ERR("migrate pull: cannot resolve src addr %s", src_addr.c_str());
        return -1;
    }
    hg_handle_t handle = NULL;
    if (HG_Create(hg_context, addr, g_migrate_chunk_id, &handle) != HG_SUCCESS) {
        HG_Addr_free(hg_class, addr);
        return -1;
    }
    hg_size_t bsz = (hg_size_t)len;
    hg_bulk_t local_bulk = HG_BULK_NULL;
    if (HG_Bulk_create(hg_class, 1, &buf, &bsz, HG_BULK_WRITE_ONLY, &local_bulk) != HG_SUCCESS) {
        HG_Destroy(handle); HG_Addr_free(hg_class, addr);
        return -1;
    }

    // Path fits a stack buffer (bounded by the filesystem PATH_MAX); no malloc,
    // and HG_Forward serializes the input synchronously so the buffer is only
    // needed until HG_Forward returns.
    char path_buf[4096];
    if (path.size() >= sizeof(path_buf)) {
        HG_Bulk_free(local_bulk); HG_Destroy(handle); HG_Addr_free(hg_class, addr);
        return -1;
    }
    (void)snprintf(path_buf, sizeof(path_buf), "%s", path.c_str());

    MigratePullState *st = new MigratePullState();
    st->handle     = handle;
    st->local_bulk = local_bulk;
    st->addr       = addr;

    fitcache_migrate_chunk_in_t in;
    in.path        = path_buf;
    in.offset      = offset;
    in.len         = len;
    in.bulk_handle = local_bulk;

    hg_return_t hr = HG_Forward(handle, fitcache_migrate_pull_cb, st, &in);

    int64_t result = -1;
    if (hr != HG_SUCCESS) {
        L4C_ERR("migrate pull: HG_Forward failed %d", hr);
        migrate_pull_release(st);           // callback will not fire; drop its ref
    } else {
        std::unique_lock<std::mutex> lk(st->m);
        auto deadline = std::chrono::steady_clock::now()
                      + std::chrono::seconds(migrate_pull_timeout_sec());
        if (st->cv.wait_until(lk, deadline, [&] { return st->done; })) {
            result = st->ret;
        } else {
            L4C_ERR("migrate pull: timeout on chunk @%lld of %s",
                    (long long)offset, path.c_str());
            HG_Cancel(st->handle);          // force the callback to fire (HG_CANCELED)
            result = -1;
        }
    }

    migrate_pull_release(st);               // drop the waiter ref (last out tears down)
    return result;
}