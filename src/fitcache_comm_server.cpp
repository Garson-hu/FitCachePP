#include "fitcache_comm.h"
#include "fitcache_cluster_registry.h"
#include "fitcache_cross_job.h"
#include "fitcache_data_mover_internal.h"
#include "fitcache_cache_policy.h"
#include "fitcache_logging.h"
#include "fitcache_timer.h"

#include <atomic>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <cassert>
#include <cerrno>
#include <map>
#include <string>
#include <cstdio>
#include <cstring>
#include <ctime>
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

// State carried across all peer_lookup callbacks for one in-flight open.
// refcount cleanup model:
//   start at 1 (issuer holds a ref)
//   bump by 1 per successful HG_Forward
//   release once on issuer's exit
//   release once per callback
struct OpenPeerLookupState {
    hg_handle_t       open_handle;
    std::string       original_path;
    std::atomic<int>  refcount;
    std::atomic<int>  responses_remaining;
    std::atomic<bool> responded;
    pthread_mutex_t   respond_mtx;
    std::string       peer_addr_winner;   // protected by respond_mtx
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

// Mercury callback fired when one peer's peer_lookup_rpc response arrives.
static hg_return_t peer_lookup_response_cb(const struct hg_cb_info *info) {
    OpenPeerLookupState *st = (OpenPeerLookupState *)info->arg;
    fitcache_peer_lookup_out_t out;
    bool got_yes = false;
    std::string winner_addr;

    if (info->ret == HG_SUCCESS &&
        HG_Get_output(info->info.forward.handle, &out) == HG_SUCCESS) {
        if (out.has == 1 && out.serve_addr != NULL && out.serve_addr[0] != '\0') {
            got_yes     = true;
            winner_addr = out.serve_addr;
        }
        HG_Free_output(info->info.forward.handle, &out);
    }
    HG_Destroy(info->info.forward.handle);

    bool should_redirect = false;
    bool should_fallback = false;

    pthread_mutex_lock(&st->respond_mtx);
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

    if (should_redirect) respond_open_redirect(st);
    if (should_fallback) respond_open_pfs(st);

    state_release(st);
    return HG_SUCCESS;
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
                hg_return_t hr = HG_Forward(lookup_handle, peer_lookup_response_cb, st, &lookup_in);
                HG_Addr_free(hg_class, peer_hg_addr);
                if (hr != HG_SUCCESS) {
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
        std::unique_lock<std::shared_mutex> wlock(cache_mtx);
        fd_to_path[out.ret_status] = path_str;
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

    if (fitcache_rpc_state_p->in.offset == -1){
        // NOTE: requested_tier is a hint for future per-tier file selection.
        // Current prototype uses the already-opened fd mapping; tier selection
        // is performed by path redirection at open/close time.
        readbytes = read(fitcache_rpc_state_p->in.accessfd, fitcache_rpc_state_p->buffer, fitcache_rpc_state_p->size);
        if(DEBUG_HU)
        {
            std::string path_copy;
            {
                std::shared_lock<std::shared_mutex> rlock(cache_mtx);
                auto it = fd_to_path.find(fitcache_rpc_state_p->in.accessfd);
                if (it != fd_to_path.end())
                    path_copy = it->second;    
            }
            L4C_DEBUG("Server Rank %d : Read %ld bytes from file %s", server_rank,readbytes, path_copy.c_str());
        }
        
    }else
    {
        // See note above regarding requested_tier pseudo logic.
        readbytes = pread(fitcache_rpc_state_p->in.accessfd, fitcache_rpc_state_p->buffer, fitcache_rpc_state_p->size, fitcache_rpc_state_p->in.offset);
        if(DEBUG_HU)
        {
            L4C_DEBUG("Server Rank %d : PRead %ld bytes from file %s at offset %lld", server_rank, readbytes, fd_to_path[fitcache_rpc_state_p->in.accessfd].c_str(),(long long) fitcache_rpc_state_p->in.offset );
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
// path-level match is conservative for Phase 2b: the same path
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

    bool found = false;
    {
        std::shared_lock<std::shared_mutex> rlock(cache_mtx);
        auto it = path_cache_map.find(in.path);
        found = (it != path_cache_map.end());
    }

    const std::string &my_addr = fitcache_comm_get_self_addr_string();

    if (found) {
        fitcache::cross_job_counter_bump_peer_lookup_has_yes();
        out.has        = 1;
        out.tier       = (int32_t)CACHE_TIER_DRAM;
        out.serve_addr = const_cast<char *>(my_addr.c_str());
        L4C_INFO("peer_lookup: rank=%d path=%s -> HAS (serve_addr=%s)",
                 server_rank, in.path, my_addr.c_str());
    } else {
        fitcache::cross_job_counter_bump_peer_lookup_has_no();
        out.has        = 0;
        out.tier       = 0;
        out.serve_addr = const_cast<char *>("");
        L4C_INFO("peer_lookup: rank=%d path=%s -> NOT HAS",
                 server_rank, in.path);
    }
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