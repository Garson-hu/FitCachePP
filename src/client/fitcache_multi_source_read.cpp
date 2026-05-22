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

extern std::map<int, int > fd_redir_map;
// extern map<int,string> fd_to_path;             // & Server File Descriptor -> Original path
extern std::map<int,std::string> fd_map;	


static hg_return_t ms_read_cb(const struct hg_cb_info *info);

extern uint32_t g_fitcache_server_count;

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
        ms->completed = true;
        pthread_cond_signal(&ms->cond);
    } else 
    {
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
// same libstdc++, so the hash matches. A cached copy is "complete" iff it
// exists AND its size equals the original PFS file's size (the data mover
// does a full fs::copy before the file is usable). No RPC.
// ============================================================
extern "C" int fitcache_resolve_cached_path(const char *original_path,
                                            char *out, size_t outsz)
{
    if (!original_path || !out || outsz == 0) return 0;

    // Original file size = completeness reference.
    struct stat ost;
    if (stat(original_path, &ost) != 0 || ost.st_size <= 0) return 0;
    const off_t orig_size = ost.st_size;

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
        if (stat(cand.c_str(), &cst) == 0 && S_ISREG(cst.st_mode) &&
            cst.st_size == orig_size) {
            // Warm hit: complete local cached copy.
            std::strncpy(out, cand.c_str(), outsz - 1);
            out[outsz - 1] = '\0';
            return 1;
        }
    }
    return 0;  // miss
}
