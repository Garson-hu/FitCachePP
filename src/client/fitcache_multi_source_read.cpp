#include <pthread.h>
#include <cstdio>
#include <cstdlib>
#include <cassert>
#include <cstring>
#include <mutex>
#include <vector>
#include <string>
#include <functional>
#include <condition_variable>
#include <sys/stat.h>

#include "fitcache_internal.h"        // For fitcache_file_tracked, fitcache_get_path, etc.
#include "fitcache_comm.h"
#include "fitcache_cache_policy.h"
#include "fitcache_cross_job.h"
#include "fitcache_multi_source_read.h"
#include "fitcache_logging.h"         // For L4C_INFO, L4C_ERR
#include "fitcache_timer.h"           // FitCache_TIMING per-path tags
#include "fitcache_persistent_meta.h" // meta_read_sidecar: local completeness gate

extern std::map<int, int > fd_redir_map;
// extern map<int,string> fd_to_path;             // & Server File Descriptor -> Original path
extern std::map<int,std::string> fd_map;	


static hg_return_t ms_read_cb(const struct hg_cb_info *info);

extern uint32_t g_fitcache_server_count;
extern "C" void fitcache_client_ensure_comm_init();

// Prefetch hint API (TPDS). Resolve the owning server slot for `path` the same
// way ms_read routes reads, then forward a fire-and-forget prefetch hint so the
// server promotes the file ahead of the mmap. Non-blocking; returns 0 on send.
extern "C" int fitcache_prefetch(const char *original_path, int replication_mode)
{
    if (!original_path || !original_path[0]) return -1;
    if (g_fitcache_server_count == 0) return -1;
    // The open interceptor inits Mercury lazily on first open; prefetch may run
    // before any open, so ensure the client comm is up before forwarding.
    fitcache_client_ensure_comm_init();
    std::string path(original_path);
    int slot = fitcache::select_server_for_path(path,
                                                static_cast<int>(g_fitcache_server_count));
    if (slot < 0) return -1;
    fitcache_client_comm_gen_prefetch_rpc(static_cast<uint32_t>(slot), path,
                                          replication_mode, 0);
    return 0;
}

// ============================================================
// Adaptive placement decision (TPDS adaptive caching, 2026-07).
// Pure client-side decision: one lstat per dataset file + a statvfs of the
// local NVMe tier. No RPC, no data movement. See the header for the policy.
// Budget resolution order:
//   FITCACHE_ADAPTIVE_BUDGET (test override, bytes)
//   min(statvfs(FitCache_NVME_PATH) available bytes, FitCache_NVME_CAPACITY)
// A 5% headroom is reserved: replication requires dataset <= 0.95 * budget,
// matching the populate target the ladder jobs use.
// ============================================================
#include <sys/statvfs.h>
#include <ctime>

static inline double fitcache_adaptive_now_us()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

extern "C" int fitcache_adaptive_decide(const char *const *paths,
                                        const int *owned, int npaths,
                                        fitcache_adaptive_decision_t *out)
{
    if (!paths || npaths <= 0 || !out) return -1;
    const double t0 = fitcache_adaptive_now_us();
    memset(out, 0, sizeof(*out));

    // --- scan: dataset + owned sizes (one lstat per file) -----------------
    uint64_t total = 0, owned_total = 0;
    int seen = 0;
    for (int i = 0; i < npaths; ++i) {
        if (!paths[i] || !paths[i][0]) continue;
        struct stat st;
        if (stat(paths[i], &st) != 0 || !S_ISREG(st.st_mode)) continue;
        total += (uint64_t)st.st_size;
        if (!owned || owned[i]) owned_total += (uint64_t)st.st_size;
        ++seen;
    }
    if (seen == 0) return -2;  // unreadable dataset

    // --- budget: usable local cache bytes ---------------------------------
    uint64_t budget = 0;
    const char *ov = getenv("FITCACHE_ADAPTIVE_BUDGET");
    if (ov && ov[0]) {
        budget = strtoull(ov, nullptr, 10);
    } else {
        const char *nvme = getenv("FitCache_NVME_PATH");
        if (nvme && nvme[0]) {
            struct statvfs vfs;
            if (statvfs(nvme, &vfs) == 0)
                budget = (uint64_t)vfs.f_bavail * (uint64_t)vfs.f_frsize;
        }
        const char *cap = getenv("FitCache_NVME_CAPACITY");
        if (cap && cap[0]) {
            uint64_t c = strtoull(cap, nullptr, 10);
            if (c > 0 && (budget == 0 || c < budget)) budget = c;
        }
    }

    // --- policy ------------------------------------------------------------
    // owned!=NULL: the loader declared a partition -> every access is already
    // local under 1x; replication buys nothing regardless of capacity.
    // owned==NULL: any node may touch any byte; replicate iff it fits.
    if (owned) {
        out->mode = FITCACHE_PLACE_PARTITION_1X;
        out->replication_mode = 1;                 // SINGLE_COPY
    } else if (total <= (uint64_t)(0.95 * (double)budget)) {
        out->mode = FITCACHE_PLACE_REPLICATE_NX;
        out->replication_mode = 0;                 // UNBOUNDED
    } else {
        out->mode = FITCACHE_PLACE_PART_FALLBACK;  // cache-on-miss hot set;
        out->replication_mode = 0;                 // overflow reads -> PFS
    }
    out->dataset_bytes = total;
    out->owned_bytes   = owned_total;
    out->budget_bytes  = budget;
    out->decide_us     = fitcache_adaptive_now_us() - t0;

    L4C_INFO("adaptive_decide: mode=%d files=%d dataset=%llu owned=%llu "
             "budget=%llu decide_us=%.1f",
             out->mode, seen,
             (unsigned long long)out->dataset_bytes,
             (unsigned long long)out->owned_bytes,
             (unsigned long long)out->budget_bytes, out->decide_us);
    fitcache::add_value("adaptive.decide_us", out->decide_us);
    return 0;
}

ssize_t ms_read(int fd, void* buf, size_t count, int64_t offset)
{

    // Check if file is tracked, otherwise fallback to normal read
    if (!fitcache_file_tracked(fd))
    {
        FitCache_TIMING("ms_read.untracked");
        MAP_OR_FAIL(read);
        // L4C_INFO("File not tracked, falling back to normal read");
        if(offset == -1)
        {
            return __real_read(fd, buf, count);
        }
        else
        {
            MAP_OR_FAIL(pread);
            return __real_pread(fd, buf, count, offset);
        }
    }

    // Race-safe early bypass: if the open RPC's callback hasn't populated
    // fd_redir_map[fd] yet (== 0), the server doesn't know about our local fd
    // and would try pread(0, ...) which reads STDIN and fails. The reference
    // HVAC code guards this at hvac_remote_pread() level with
    //   if (hvac_file_tracked(fd) && fd_redir_map[fd] != 0)
    // We do the same here so the wrapper falls back to __real_read /
    // __real_pread on the LOCAL fd that the application got from __real_open.
    // This is the "fire-and-forget open + read-from-local-until-cache-ready"
    // protocol that gives cold-epoch wall ≈ Pure_CF.
    if (fd_redir_map.find(fd) == fd_redir_map.end() || fd_redir_map[fd] == 0) {
        FitCache_TIMING("ms_read.bypass_pfs");
        MAP_OR_FAIL(read);
        if (offset == -1) {
            return __real_read(fd, buf, count);
        } else {
            MAP_OR_FAIL(pread);
            return __real_pread(fd, buf, count, offset);
        }
    }

    // Path-specific timing: distinguishes peer-redirect from HRW-normal so the
    // shutdown summary can quantify Mercury bulk + redirect/retry overhead.
    int override_slot_probe = fitcache_client_get_peer_slot_override(fd);
    fitcache::TimerGuard __ms_read_total_tg__(
        override_slot_probe >= 0 ? "ms_read.peer_redirect_total"
                                 : "ms_read.hrw_normal_total");

    L4C_INFO("File tracked, using multi-source read, the file descriptor is %d", fd);

    // Create ms_read_state to store asynchronous results
    ms_read_state *ms = (ms_read_state*) calloc(1, sizeof(ms_read_state));
    pthread_mutex_init(&ms->lock, NULL);
    pthread_cond_init(&ms->cond, NULL);
    ms->completed = false;
    ms->pm_done = false;
    ms->ssd_done = false;
    ms->pm_result = -1;
    ms->ssd_result= -1;

    fitcache_rpc_state* dram_state = (fitcache_rpc_state*) calloc(1, sizeof(fitcache_rpc_state));
    dram_state->ms = ms;
    dram_state->buffer = buf;
    dram_state->size = count;
    dram_state->requested_tier = CACHE_TIER_DRAM;

    fitcache_rpc_state* nvme_state = (fitcache_rpc_state*) calloc(1, sizeof(fitcache_rpc_state));
    nvme_state->ms = ms;
    nvme_state->buffer = buf;
    nvme_state->size = count;
    nvme_state->requested_tier = CACHE_TIER_NVME;

    int remote_fd = fd_redir_map[fd];
    L4C_INFO("Remote fd: %d", remote_fd);
    // Cross-job peer-fanout: if the open returned a redirect to a peer,
    // route this read to that peer too. Without this the remote_fd from the
    // peer is sent to the HRW-chosen server (which doesn't know that fd) and
    // the read fails.
    int override_slot = fitcache_client_get_peer_slot_override(fd);
    int host = (override_slot >= 0)
        ? override_slot
        : fitcache::select_server_for_path(fd_map[fd],
            static_cast<int>(g_fitcache_server_count));
    if (override_slot >= 0) {
        L4C_INFO("ms_read: peer-slot override %d active for fd %d", override_slot, fd);
    }

    fitcache::add_value("ms_read.fetch_rpcs_issued", 1.0);
    fitcache_client_comm_gen_read_rpc_with_ms(host, fd, buf, count, offset,
        ms_read_cb, dram_state);
    
    L4C_INFO("Generated read rpc with ms");
    ssize_t final_result = -1;
    bool done = false;

    pthread_mutex_lock(&ms->lock);

    while(!ms->completed) 
    {
        pthread_cond_wait(&ms->cond, &ms->lock);
    }

    if(ms->pm_done && ms->pm_result != -1) 
    {
        final_result = ms->pm_result;
        done = true;
    }
    else if(ms->ssd_done && ms->ssd_result != -1) 
    {
        final_result = ms->ssd_result;
        done = true;
    }
    pthread_mutex_unlock(&ms->lock);
    if(DEBUG_HU)
    {
        L4C_INFO("Final result: %ld", final_result);
        L4C_INFO("ms->pm_done: %d, ms->ssd_done: %d", ms->pm_done, ms->ssd_done);
        L4C_INFO("ms->pm_result: %ld, ms->ssd_result: %ld", ms->pm_result, ms->ssd_result);
    }

    // 7. Clean up
    free(dram_state);
    free(nvme_state);
    pthread_mutex_destroy(&ms->lock);
    pthread_cond_destroy(&ms->cond);
    free(ms);
    // 8. Return whichever result completed first
    return final_result;
}

static hg_return_t ms_read_cb(const struct hg_cb_info *info)
{
    fitcache_rpc_state* state = (fitcache_rpc_state*) info->arg;
    ms_read_state* ms = state->ms;


    if(info->ret != HG_SUCCESS) 
    {
        L4C_INFO("RPC failed");
        pthread_mutex_lock(&ms->lock);
        if(state->requested_tier == CACHE_TIER_DRAM) 
        {
            ms->pm_done = true;
            ms->pm_result = -1;
        }
        else if(state->requested_tier == CACHE_TIER_NVME) 
        {
            ms->ssd_done = true;
            ms->ssd_result = -1;
        }

        if (!ms->completed) 
        {
            // check if the other request is done or not
            if ((ms->pm_done && ms->ssd_done) &&
                (ms->pm_result < 0 && ms->ssd_result < 0)) 
                {
                // both fail => complete
                ms->completed = true;
                pthread_cond_signal(&ms->cond);
            }
        }
        pthread_mutex_unlock(&ms->lock);

        if (state->bulk_handle != HG_BULK_NULL) {
            HG_Bulk_free(state->bulk_handle);
        }
        HG_Destroy(info->info.forward.handle);

        return HG_SUCCESS;
    }

    fitcache_rpc_out_t out;
    hg_return_t ret = HG_Get_output(info->info.forward.handle, &out);
    if (ret != HG_SUCCESS) 
    {
        // handle error
        pthread_mutex_lock(&ms->lock);
        if (state->requested_tier == CACHE_TIER_DRAM) 
        {
            ms->pm_done    = true;
            ms->pm_result  = -1;
        } else {
            ms->ssd_done   = true;
            ms->ssd_result = -1;
        }
        // check if both done => complete
        if (!ms->completed) 
        {
            if ((ms->pm_done && ms->ssd_done) &&
                (ms->pm_result < 0 && ms->ssd_result < 0)) 
                {
                ms->completed = true;
                pthread_cond_signal(&ms->cond);
            }
        }
        pthread_mutex_unlock(&ms->lock);

        // TODO: add destroy in here.
        if (state->bulk_handle != HG_BULK_NULL) {
            HG_Bulk_free(state->bulk_handle);
        }
        HG_Destroy(info->info.forward.handle);

        return HG_SUCCESS;
    }

    ssize_t bytes_read = out.ret;
    fitcache_rpc_state *rpc = state;

    ret = HG_Bulk_free(rpc->bulk_handle);
    ret = HG_Free_output(info->info.forward.handle, &out);
    ret = HG_Destroy(info->info.forward.handle);

    // success read, update ms
    pthread_mutex_lock(&ms->lock);
    if (rpc->requested_tier == CACHE_TIER_DRAM) {
        ms->pm_done   = true;
        ms->pm_result = bytes_read;
    } else if (rpc->requested_tier == CACHE_TIER_NVME)
    {
        ms->ssd_done   = true;
        ms->ssd_result = bytes_read;
    }
    // if success => set ms->completed
    if (bytes_read >= 0 && !ms->completed) {
        // P1-b traffic accounting: this response is the one delivered to the
        // application (the "winner" of the multi-source race).
        fitcache::add_value("ms_read.bytes_winner", (double)bytes_read);
        ms->completed = true;
        pthread_cond_signal(&ms->cond);
    } else 
    {
        // P1-b traffic accounting: a successful response that arrives after
        // completion carries redundant payload. Structurally this stays 0 in
        // the resolved-tier fast path (one RPC per read); the counter proves
        // it empirically.
        if (bytes_read >= 0 && ms->completed) {
            fitcache::add_value("ms_read.bytes_redundant", (double)bytes_read);
        }
        // if the other side also done or both fail => complete
        if ((ms->pm_done && ms->ssd_done) &&
            (ms->pm_result < 0 && ms->ssd_result < 0)) 
        {
            ms->completed = true;
            pthread_cond_signal(&ms->cond);
        }
    }
    pthread_mutex_unlock(&ms->lock);

    return HG_SUCCESS;
}
// ============================================================
// Warm-hit resolver for the direct-local-mmap path (2026-05-21).
// Mirrors the server data mover's cached-path scheme
// (fitcache_data_mover.cpp): cached file lives at
//   <tier_base>/<(h>>8)&0xFF>/<h&0xFF>/<basename(original_path)>
// with h = std::hash<std::string>(original_path). Client and server link the
// same libstdc++, so the hash matches. Completeness is verified LOCALLY: the
// cached file lands via an atomic rename in the data mover (so its presence
// already implies a complete copy), and the .meta sidecar -- written right
// after, on the same local tier -- records the source size as a cross-check.
// No RPC, and -- critically -- NO stat() of the original on the PFS. That
// per-mmap PFS stat was an MDS bottleneck: at 1-2k ranks it serialized every
// warm mmap on the Lustre metadata server and dropped warm bandwidth ~10x.
// ============================================================
extern "C" int fitcache_resolve_cached_path(const char *original_path,
                                            char *out, size_t outsz)
{
    if (!original_path || !out || outsz == 0) return 0;

    // Deterministic two-level hash bin (matches data_mover.cpp:482-488).
    size_t h = std::hash<std::string>{}(std::string(original_path));
    char subdir[16];
    snprintf(subdir, sizeof(subdir), "%02zx/%02zx",
             (h >> 8) & 0xFF, h & 0xFF);

    // basename of the original path.
    std::string op(original_path);
    size_t slash = op.find_last_of('/');
    std::string base = (slash == std::string::npos) ? op : op.substr(slash + 1);

    // Probe tiers in placement priority order: DRAM, PMem, NVMe.
    const char *tier_env[3] = {
        getenv("FitCache_DRAM_PATH"),
        getenv("FitCache_PMEM_PATH"),
        getenv("FitCache_NVME_PATH"),
    };
    for (int i = 0; i < 3; ++i) {
        const char *t = tier_env[i];
        if (!t || !t[0]) continue;
        std::string cand = std::string(t) + "/" + subdir + "/" + base;
        struct stat cst;
        if (stat(cand.c_str(), &cst) != 0 || !S_ISREG(cst.st_mode) ||
            cst.st_size <= 0)
            continue;  // not present on this tier
        // Local completeness gate, no PFS stat. When a .meta sidecar exists,
        // use it to reject stale/incomplete copies and hash-bin basename
        // collisions across datasets. When it does NOT exist, accept the
        // file: the prefetch/populate path lands complete cached files with
        // no sidecar (verified 2026-07-06 -- requiring one turned every
        // populated file into a miss and silently sent "warm" reads back to
        // Lustre). Presence-trust is safe against the old SIGBUS because the
        // mmap wrapper independently fstat-verifies that the cached file
        // covers the requested [offset, offset+length) before mapping; a
        // short or still-growing copy falls back to the native PFS mmap.
        fitcache::fitcache_file_meta_v1 m;
        if (fitcache::meta_read_sidecar(cand, &m) == 0) {
            if ((off_t)m.original_size != cst.st_size)
                continue;  // incomplete/stale copy
            if (std::strncmp(m.original_path, original_path,
                             sizeof(m.original_path)) != 0)
                continue;  // different source file in the same hash bin
        }
        // Warm hit: complete local cached copy.
        std::strncpy(out, cand.c_str(), outsz - 1);
        out[outsz - 1] = '\0';
        return 1;
    }
    return 0;  // miss
}


// P1-b instrumentation bridge: lets plain-C call sites (wrappers.c) record
// into the C++ stat table. Value semantics match fitcache::add_value.
extern "C" void fitcache_stat_add(const char *tag, double v)
{
    fitcache::add_value(tag, v);
}
