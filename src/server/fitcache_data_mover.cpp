/* Data mover responsible for maintaining the NVMe state
 * and prefetching the data
 */
#include <filesystem>
#include <string>
#include <queue>
#include <iostream>

#include <pthread.h>
#include <string.h>
#include <unistd.h>      // sleep()
#include <chrono>
#include <utility>
#include <vector>
#include "fitcache_logging.h"
#include "fitcache_data_mover_internal.h"
#include "fitcache_cache_policy.h"
#include "fitcache_cross_job.h"
#include "fitcache_cluster_registry.h"  // registry_record_file_presence (Option 1)
#include "fitcache_persistent_meta.h"
#include "fitcache_comm.h"               // fitcache_comm_get_self_addr_string,
                                          // fitcache_broadcast_register_file (Option 2)
using namespace std;
namespace fs = std::filesystem;

// uint64_t g_dram_capacity_bytes;
// uint64_t g_nvme_capacity_bytes;
// std::string g_dram_path;
// std::string g_nvme_path;
uint64_t g_dram_used_bytes = 0;
uint64_t g_pmem_used_bytes = 0;
uint64_t g_nvme_used_bytes = 0;

pthread_cond_t data_cond = PTHREAD_COND_INITIALIZER;
pthread_mutex_t data_mutex = PTHREAD_MUTEX_INITIALIZER;

unordered_map<int,string> fd_to_path;             // & Server File Descriptor -> Original path
unordered_map<string, string> path_cache_map;     // & Original path -> Redirection path
shared_mutex cache_mtx;                       // & Mutex for the path cache

queue<string> data_queue;               // & List of files to be moved

std::atomic<bool> fitcache_eviction_reaper_running{false};

namespace {

// Pull capacity / path / watermark / interval values from env vars. Returns
// false (and leaves outputs untouched) if the required tier env vars are
// missing — the reaper logs a warning and exits in that case.
//
// PMem tier is opt-in: when FitCache_PMEM_PATH and FitCache_PMEM_CAPACITY are
// both set, the reaper also evicts from that tier. When either is unset, the
// reaper leaves pmem_path empty (out-of-band signal to skip pmem in the loop)
// and behavior is identical to the original two-tier configuration.
bool reaper_read_env_config(std::string &dram_path, std::string &pmem_path,
                            std::string &nvme_path,
                            uint64_t &dram_cap, uint64_t &pmem_cap,
                            uint64_t &nvme_cap,
                            double   &high_wm,    double   &low_wm,
                            int      &interval_sec) {
    const char *dp = getenv("FitCache_DRAM_PATH");
    const char *np = getenv("FitCache_NVME_PATH");
    const char *dc = getenv("FitCache_DRAM_CAPACITY");
    const char *nc = getenv("FitCache_NVME_CAPACITY");
    if (!dp || !np || !dc || !nc) return false;
    dram_path = dp; nvme_path = np;
    dram_cap  = std::stoull(dc);
    nvme_cap  = std::stoull(nc);
    const char *pp = getenv("FitCache_PMEM_PATH");
    const char *pc = getenv("FitCache_PMEM_CAPACITY");
    if (pp && pp[0] && pc && pc[0]) {
        pmem_path = pp;
        pmem_cap  = std::stoull(pc);
    } else {
        pmem_path.clear();
        pmem_cap = 0;
    }
    high_wm = 0.85; low_wm = 0.70; interval_sec = 30;
    if (const char *v = getenv("FitCache_EVICT_HIGH_WM")) {
        double n = std::atof(v); if (n > 0 && n < 1.0) high_wm = n;
    }
    if (const char *v = getenv("FitCache_EVICT_LOW_WM")) {
        double n = std::atof(v); if (n > 0 && n < 1.0) low_wm = n;
    }
    if (const char *v = getenv("FitCache_REAPER_SEC")) {
        int n = std::atoi(v); if (n > 0) interval_sec = n;
    }
    return true;
}

// Take a snapshot of cached files under `tier_path` (i.e. cached files whose
// path begins with the tier root). Snapshot under cache_mtx so we don't hold
// the lock while doing per-file sidecar I/O.
std::vector<std::pair<std::string, std::string>>
snapshot_cached_files_in_tier(const std::string &tier_path) {
    std::vector<std::pair<std::string, std::string>> out;
    std::shared_lock<std::shared_mutex> rlock(cache_mtx);
    out.reserve(path_cache_map.size());
    for (const auto &kv : path_cache_map) {
        if (kv.second.compare(0, tier_path.size(), tier_path) == 0) {
            out.emplace_back(kv.first, kv.second);
        }
    }
    return out;
}

// Evict one victim from `tier_path` (refcount=0, lowest access_count). On
// success returns bytes freed and rewires path_cache_map / used_bytes;
// returns 0 if no eviction happened (no candidate or unlink failed).
uint64_t evict_one_in_tier(const std::string &tier_path,
                           uint64_t &tier_used_bytes) {
    auto snapshot = snapshot_cached_files_in_tier(tier_path);
    std::vector<std::string> cached_only;
    cached_only.reserve(snapshot.size());
    for (const auto &p : snapshot) cached_only.push_back(p.second);

    std::string victim_cached = fitcache::meta_select_eviction_victim(cached_only);
    if (victim_cached.empty()) return 0;

    // Map back to original_path for path_cache_map removal.
    std::string victim_orig;
    for (const auto &p : snapshot) {
        if (p.second == victim_cached) { victim_orig = p.first; break; }
    }
    if (victim_orig.empty()) return 0;

    uint64_t freed = fitcache::meta_evict_file(victim_cached);
    if (freed == 0) return 0;

    {
        std::unique_lock<std::shared_mutex> wlock(cache_mtx);
        path_cache_map.erase(victim_orig);
    }
    if (tier_used_bytes >= freed) tier_used_bytes -= freed;
    else                          tier_used_bytes  = 0;
    return freed;
}

}  // namespace

void *fitcache_eviction_reaper_fn(void *arg) {
    (void)arg;
    std::string dram_path, pmem_path, nvme_path;
    uint64_t dram_cap = 0, pmem_cap = 0, nvme_cap = 0;
    double high_wm = 0.85, low_wm = 0.70;
    int interval_sec = 30;
    if (!reaper_read_env_config(dram_path, pmem_path, nvme_path,
                                dram_cap, pmem_cap, nvme_cap,
                                high_wm,  low_wm,
                                interval_sec)) {
        L4C_WARN("eviction-reaper: missing tier env config; reaper exiting");
        return NULL;
    }
    const bool pmem_enabled = !pmem_path.empty() && pmem_cap > 0;
    L4C_INFO("eviction-reaper: started (interval=%ds, high_wm=%.2f, low_wm=%.2f, pmem=%s)",
             interval_sec, high_wm, low_wm, pmem_enabled ? "ON" : "OFF");

    uint64_t dram_high = (uint64_t)(high_wm * dram_cap);
    uint64_t dram_low  = (uint64_t)(low_wm  * dram_cap);
    uint64_t pmem_high = (uint64_t)(high_wm * pmem_cap);
    uint64_t pmem_low  = (uint64_t)(low_wm  * pmem_cap);
    uint64_t nvme_high = (uint64_t)(high_wm * nvme_cap);
    uint64_t nvme_low  = (uint64_t)(low_wm  * nvme_cap);

    while (fitcache_eviction_reaper_running.load()) {
        for (int i = 0; i < interval_sec && fitcache_eviction_reaper_running.load(); ++i)
            sleep(1);
        if (!fitcache_eviction_reaper_running.load()) break;

        // DRAM tier
        if (g_dram_used_bytes > dram_high) {
            L4C_INFO("eviction-reaper: DRAM over high watermark (%lu > %lu); evicting",
                     (unsigned long)g_dram_used_bytes, (unsigned long)dram_high);
            int passes = 0;
            while (g_dram_used_bytes > dram_low && passes < 1024) {
                uint64_t freed = evict_one_in_tier(dram_path, g_dram_used_bytes);
                if (freed == 0) break;             // nothing more to evict
                ++passes;
            }
        }
        // PMem tier (opt-in)
        if (pmem_enabled && g_pmem_used_bytes > pmem_high) {
            L4C_INFO("eviction-reaper: PMem over high watermark (%lu > %lu); evicting",
                     (unsigned long)g_pmem_used_bytes, (unsigned long)pmem_high);
            int passes = 0;
            while (g_pmem_used_bytes > pmem_low && passes < 1024) {
                uint64_t freed = evict_one_in_tier(pmem_path, g_pmem_used_bytes);
                if (freed == 0) break;
                ++passes;
            }
        }
        // NVMe tier
        if (g_nvme_used_bytes > nvme_high) {
            L4C_INFO("eviction-reaper: NVMe over high watermark (%lu > %lu); evicting",
                     (unsigned long)g_nvme_used_bytes, (unsigned long)nvme_high);
            int passes = 0;
            while (g_nvme_used_bytes > nvme_low && passes < 1024) {
                uint64_t freed = evict_one_in_tier(nvme_path, g_nvme_used_bytes);
                if (freed == 0) break;
                ++passes;
            }
        }
    }
    L4C_INFO("eviction-reaper: shutting down");
    return NULL;
}

int fitcache_data_mover_restore_from_sidecars()
{
    const char *dram_env = getenv("FitCache_DRAM_PATH");
    const char *pmem_env = getenv("FitCache_PMEM_PATH");
    const char *nvme_env = getenv("FitCache_NVME_PATH");
    if (!dram_env && !pmem_env && !nvme_env) {
        L4C_WARN("restore-sidecars: none of FitCache_{DRAM,PMEM,NVME}_PATH set; "
                 "nothing to scan");
        return -1;
    }

    int total_restored = 0;

    // Tag what tier each restored file belongs to so we can bump the right
    // used-bytes counter. The capture-by-reference of `target_used` lets the
    // lambda update the correct global without per-call branching.
    auto make_restorer = [&](uint64_t &target_used) {
        return [&target_used](const std::string &cached_path,
                              const fitcache::fitcache_file_meta_v1 &meta) {
            std::unique_lock<std::shared_mutex> wlock(cache_mtx);
            path_cache_map[meta.original_path] = cached_path;
            target_used += meta.original_size;
        };
    };

    if (dram_env && dram_env[0]) {
        int n = fitcache::meta_scan_tier_dir(dram_env, make_restorer(g_dram_used_bytes));
        if (n > 0) {
            L4C_INFO("restore-sidecars: restored %d files from DRAM tier %s",
                     n, dram_env);
            total_restored += n;
        }
    }
    if (pmem_env && pmem_env[0]) {
        int n = fitcache::meta_scan_tier_dir(pmem_env, make_restorer(g_pmem_used_bytes));
        if (n > 0) {
            L4C_INFO("restore-sidecars: restored %d files from PMem tier %s",
                     n, pmem_env);
            total_restored += n;
        }
    }
    if (nvme_env && nvme_env[0]) {
        int n = fitcache::meta_scan_tier_dir(nvme_env, make_restorer(g_nvme_used_bytes));
        if (n > 0) {
            L4C_INFO("restore-sidecars: restored %d files from NVMe tier %s",
                     n, nvme_env);
            total_restored += n;
        }
    }
    L4C_INFO("restore-sidecars: total restored = %d", total_restored);
    return total_restored;
}

// ============================================================
// Cross-job sibling-cache refresh.
// ------------------------------------------------------------
// All FitCache server processes on the same node write their cached files
// (and matching `.meta` sidecars) into the SAME tier directories
// (FitCache_DRAM_PATH / _PMEM_PATH / _NVME_PATH). But each process's
// path_cache_map is in-process — it only contains files THIS process
// promoted. When a peer_lookup_rpc arrives at this process for a file
// that a *sibling* process on this node has cached, the handler returns
// has=0 even though the cached file is sitting on the shared local
// disk and is readable from this process. That's the per-server-process
// path_cache_map partitioning gap identified in the two-job concurrent
// cross-job-sharing run analysis.
//
// The fix: periodically re-scan the local tier directories and merge any
// not-yet-known sidecars into THIS process's path_cache_map. After a
// refresh tick, peer_lookup at this process correctly answers has=1 for
// anything any sibling on this node has cached, and the existing open-rpc
// handler path serves the file from local disk via Mercury just as
// though this process had cached it itself.
//
// De-dups against the existing path_cache_map by original_path so a
// refresh tick never double-inserts or alters used-bytes counters (those
// are owned by the data-mover thread that physically promoted the file).
// ============================================================
std::atomic<bool> fitcache_sibling_refresh_running{false};

int fitcache_data_mover_refresh_from_siblings_once()
{
    const char *dram_env = getenv("FitCache_DRAM_PATH");
    const char *pmem_env = getenv("FitCache_PMEM_PATH");
    const char *nvme_env = getenv("FitCache_NVME_PATH");
    if (!dram_env && !pmem_env && !nvme_env) return 0;

    int added = 0;
    auto adder = [&added](const std::string &cached_path,
                          const fitcache::fitcache_file_meta_v1 &meta) {
        std::unique_lock<std::shared_mutex> wlock(cache_mtx);
        if (path_cache_map.find(meta.original_path) == path_cache_map.end()) {
            path_cache_map[meta.original_path] = cached_path;
            ++added;
        }
    };

    if (dram_env && dram_env[0]) fitcache::meta_scan_tier_dir(dram_env, adder);
    if (pmem_env && pmem_env[0]) fitcache::meta_scan_tier_dir(pmem_env, adder);
    if (nvme_env && nvme_env[0]) fitcache::meta_scan_tier_dir(nvme_env, adder);
    return added;
}

void *fitcache_sibling_refresh_fn(void *arg)
{
    (void)arg;
    int interval_sec = 10;
    if (const char *v = getenv("FitCache_SIBLING_REFRESH_SEC")) {
        int n = std::atoi(v); if (n > 0) interval_sec = n;
    }
    L4C_INFO("sibling-refresh: thread starting, interval=%ds", interval_sec);
    while (fitcache_sibling_refresh_running.load()) {
        // Sleep in 1-second slices so shutdown is responsive.
        for (int i = 0; i < interval_sec && fitcache_sibling_refresh_running.load(); ++i)
            sleep(1);
        if (!fitcache_sibling_refresh_running.load()) break;
        int added = fitcache_data_mover_refresh_from_siblings_once();
        if (added > 0) {
            L4C_INFO("sibling-refresh: merged %d new path_cache_map entries "
                     "from sibling sidecars", added);
        }
    }
    L4C_INFO("sibling-refresh: thread exiting");
    return NULL;
}

void *fitcache_data_mover_fn(void *args)
{
    if(getenv("FitCache_DRAM_PATH")  == NULL)
    {
        L4C_FATAL("Please set environment variables FitCache_DRAM_PATH\n");
        return NULL;
    }

    string g_dram_path = string(getenv("FitCache_DRAM_PATH"));

    if(getenv("FitCache_NVME_PATH")  == NULL)
    {
        L4C_FATAL("Please set environment variables FitCache_NVME_PATH\n");
        return NULL;
    }

    string g_nvme_path = string(getenv("FitCache_NVME_PATH"));

    if(getenv("FitCache_DRAM_CAPACITY")  == NULL)
    {
        L4C_FATAL("Please set environment variables FitCache_DRAM_CAPACITY\n");
        return NULL;
    }

    char* g_dram_capacity_tmp  = getenv("FitCache_DRAM_CAPACITY");
    uint64_t g_dram_capacity_bytes = std::stoull(g_dram_capacity_tmp);

    if(getenv("FitCache_NVME_CAPACITY")  == NULL)
    {
        L4C_FATAL("Please set environment variables FitCache_NVME_CAPACITY\n");
        return NULL;
    }

    char* g_nvme_capacity_tmp  = getenv("FitCache_NVME_CAPACITY");
    uint64_t g_nvme_capacity_bytes = std::stoull(g_nvme_capacity_tmp);

    // PMem tier is opt-in: both FitCache_PMEM_PATH and FitCache_PMEM_CAPACITY
    // must be set. When either is missing the tier is disabled and placement
    // falls back to the original two-tier (DRAM -> NVMe) policy. Designed for
    // the three-tier hardware-evaluation experiment on the PMem-equipped node.
    const char *pmem_path_env = getenv("FitCache_PMEM_PATH");
    const char *pmem_cap_env  = getenv("FitCache_PMEM_CAPACITY");
    string g_pmem_path;
    uint64_t g_pmem_capacity_bytes = 0;
    const bool pmem_tier_enabled = (pmem_path_env && pmem_path_env[0] &&
                                    pmem_cap_env  && pmem_cap_env[0]);
    if (pmem_tier_enabled) {
        g_pmem_path            = string(pmem_path_env);
        g_pmem_capacity_bytes  = std::stoull(pmem_cap_env);
    }

    L4C_INFO("FitCache_DRAM_PATH is set to %s", g_dram_path.c_str());
    L4C_INFO("FitCache_NVME_PATH is set to %s", g_nvme_path.c_str());
    L4C_INFO("FitCache_DRAM_CAPACITY is set to %llu", g_dram_capacity_bytes);
    L4C_INFO("FitCache_NVME_CAPACITY is set to %llu", g_nvme_capacity_bytes);
    if (pmem_tier_enabled) {
        L4C_INFO("FitCache_PMEM_PATH is set to %s", g_pmem_path.c_str());
        L4C_INFO("FitCache_PMEM_CAPACITY is set to %llu", g_pmem_capacity_bytes);
    } else {
        L4C_INFO("PMem tier DISABLED (FitCache_PMEM_PATH and/or FitCache_PMEM_CAPACITY unset)");
    }

    queue<string> local_list;

    // string fsdax_base = string(fsdax_path) + "/XXXXXX";
    // string ssd_base   = string(ssd_path)   + "/XXXXXX";

    string dram_base = string(g_dram_path);
    string pmem_base = g_pmem_path;       // empty if PMem disabled
    string nvme_base = string(g_nvme_path);

    while (1) {
        pthread_mutex_lock(&data_mutex);
        // BUG FIX (2026-05-11): the previous unconditional pthread_cond_wait
        // dropped signals fired while the mover was busy. Producer (close
        // RPC handler) signals after pushing to data_queue; if the consumer
        // is still processing a prior batch when the signal fires, the
        // signal is lost (pthread_cond_signal has no memory of unconsumed
        // signals). The consumer then loops back to wait() with files still
        // in queue but no remaining signal to wake it — the queue gets
        // stuck forever. Reproduced via the Megatron access-pattern smoke:
        // a 2-file workload (.bin + .idx) consistently leaves the second
        // file unprocessed. The standard pthread_cond pattern is to test
        // the predicate (queue non-empty) before AND after waking, which
        // turns the wait into a no-op when work is already pending.
        while (data_queue.empty()) {
            pthread_cond_wait(&data_cond, &data_mutex);
        }

        int queue_size = data_queue.size();
        L4C_INFO("DEBUG: Data queue size: %d", queue_size);
        /* Drain the queue under the mutex into a local list, then process
         * outside the lock so producers can keep pushing during the copy. */
        while (!data_queue.empty()){
            local_list.push(data_queue.front());
            data_queue.pop();
        }

        pthread_mutex_unlock(&data_mutex);

        while (!local_list.empty())
        {
            L4C_INFO("Data mover: Moving file %s", local_list.front().c_str());
            string original_path = local_list.front();

            // (&used_dram_bytes, &used_nvme_bytes);

            // Determine target tier by checking remaining capacity with file size.
            // Placement priority: DRAM -> PMem (if enabled) -> NVMe.
            cache_tier_t target_tier = CACHE_TIER_DRAM;
            uint64_t file_size = 0;
            try {
                file_size = fs::file_size(original_path);
            } catch (const fs::filesystem_error &e) {
                L4C_ERR("Data mover: failed to stat %s: %s", original_path.c_str(), e.what());
                local_list.pop();
                continue;
            }

            if (g_dram_used_bytes + file_size <= g_dram_capacity_bytes) {
                target_tier = CACHE_TIER_DRAM;
            } else if (pmem_tier_enabled &&
                       g_pmem_used_bytes + file_size <= g_pmem_capacity_bytes) {
                target_tier = CACHE_TIER_PMEM;
            } else if (g_nvme_used_bytes + file_size <= g_nvme_capacity_bytes) {
                target_tier = CACHE_TIER_NVME;
            } else {
                L4C_ERR("No space in DRAM%s or NVME to move file %s\n",
                        pmem_tier_enabled ? "/PMem" : "",
                        original_path.c_str());
                local_list.pop();
                continue;
            }

            // Simple hash bucket implementation
            string basepath;
            switch (target_tier) {
                case CACHE_TIER_DRAM: basepath = dram_base; break;
                case CACHE_TIER_PMEM: basepath = pmem_base; break;
                case CACHE_TIER_NVME: basepath = nvme_base; break;
                default:              basepath = nvme_base; break;
            }
            // Retain `to_dram` as a legacy local for the sidecar/logging
            // section below — it's true iff the file landed in DRAM. PMem and
            // NVMe both report as "not DRAM" in the existing sidecar metadata
            // (which only persists size/dataset, not tier).
            const bool to_dram = (target_tier == CACHE_TIER_DRAM);
            L4C_INFO("Basepath %s", basepath.c_str());
            size_t h = std::hash<std::string>{}(original_path);
            char subdir[8];
            sprintf(subdir, "%02zx/%02zx", (h >> 8) & 0xFF, h & 0xFF);
            string dirpath = basepath + "/" + subdir;
            fs::create_directories(dirpath);
            L4C_INFO("Creating directory %s", dirpath.c_str());
            string filename = dirpath + "/" + fs::path(original_path).filename().string();

            try{
                fs::copy(original_path, filename);
                path_cache_map[original_path] = filename;
                // Update the used bytes for whichever tier we landed in.
                switch (target_tier) {
                    case CACHE_TIER_DRAM: g_dram_used_bytes += file_size; break;
                    case CACHE_TIER_PMEM: g_pmem_used_bytes += file_size; break;
                    case CACHE_TIER_NVME: g_nvme_used_bytes += file_size; break;
                    default:              g_nvme_used_bytes += file_size; break;
                }
                if(DEBUG_HU) {
                    const char *tier_name = (target_tier == CACHE_TIER_DRAM) ? "DRAM"
                                          : (target_tier == CACHE_TIER_PMEM) ? "PMem"
                                          : "NVMe";
                    L4C_INFO("Data mover: Copied %s -> %s (tier=%s)",
                             original_path.c_str(), filename.c_str(), tier_name);
                }

                // Cross-job durability: write a sidecar so this cache survives
                // server restart and can be discovered by peer-job lookups.
                // Only meaningful in cross-job mode; in single-job mode the
                // sidecar is harmless extra metadata.
                if (fitcache::cross_job_enabled()) {
                    // Tag the sidecar with this process's dataset manifest_hash
                    // (populated by subscribe_self_to_local_dataset via the full
                    // build_dataset_id scan). 0 means "this process never
                    // subscribed", which is the smoke-test path; production
                    // server startup always subscribes before promotions.
                    fitcache::fitcache_file_meta_v1 meta =
                        fitcache::meta_make_initial(
                            original_path,
                            file_size,
                            fitcache::get_self_dataset_manifest_hash());
                    if (fitcache::meta_write_sidecar(filename, meta) != 0) {
                        L4C_WARN("Data mover: failed to write sidecar for %s",
                                 filename.c_str());
                    } else if (DEBUG_HU) {
                        L4C_INFO("Data mover: wrote sidecar for %s",
                                 filename.c_str());
                    }

                    // Cross-job has_yes=0 fix Option 1: record our presence
                    // on PFS so peer-job servers can find us in their
                    // peer_lookup_rpc handlers. This closes the race where
                    // a peer queries us between open-time (path_cache_map
                    // empty) and now (cache populated) — the PFS record is
                    // durable and is consulted in addition to path_cache_map.
                    const std::string &self_addr =
                        fitcache_comm_get_self_addr_string();
                    if (!self_addr.empty()) {
                        int prc = fitcache::registry_record_file_presence(
                            original_path, self_addr,
                            fitcache::get_self_dataset_manifest_hash());
                        if (prc == 0 && DEBUG_HU) {
                            L4C_INFO("Data mover: recorded PFS presence for %s",
                                     original_path.c_str());
                        }
                    }

                    // Cross-job has_yes=0 fix Option 2: broadcast a
                    // register-file RPC to every live peer so their
                    // in-memory remote_presence_map gets updated without
                    // needing a PFS read on every peer_lookup. PFS presence
                    // (Option 1) is the durable source-of-truth; this RPC
                    // is the fast in-cluster path.
                    fitcache_broadcast_register_file(original_path);
                }

            } catch (const fs::filesystem_error& e)
            {
                fprintf(stderr, "Error : %s copying from %s to %s\n", e.what(), original_path.c_str(), filename.c_str());
                L4C_INFO("Failed to copy %s to %s\n", original_path.c_str(), filename.c_str());
            }
            
            local_list.pop();
        }
    }
    return NULL;
}
