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
#include "fitcache_persistent_meta.h"
using namespace std;
namespace fs = std::filesystem;

// uint64_t g_dram_capacity_bytes;
// uint64_t g_nvme_capacity_bytes;
// std::string g_dram_path;
// std::string g_nvme_path;
uint64_t g_dram_used_bytes = 0;
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
bool reaper_read_env_config(std::string &dram_path, std::string &nvme_path,
                            uint64_t &dram_cap, uint64_t &nvme_cap,
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
    std::string dram_path, nvme_path;
    uint64_t dram_cap = 0, nvme_cap = 0;
    double high_wm = 0.85, low_wm = 0.70;
    int interval_sec = 30;
    if (!reaper_read_env_config(dram_path, nvme_path,
                                dram_cap, nvme_cap,
                                high_wm,   low_wm,
                                interval_sec)) {
        L4C_WARN("eviction-reaper: missing tier env config; reaper exiting");
        return NULL;
    }
    L4C_INFO("eviction-reaper: started (interval=%ds, high_wm=%.2f, low_wm=%.2f)",
             interval_sec, high_wm, low_wm);

    uint64_t dram_high = (uint64_t)(high_wm * dram_cap);
    uint64_t dram_low  = (uint64_t)(low_wm  * dram_cap);
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
    const char *nvme_env = getenv("FitCache_NVME_PATH");
    if (!dram_env && !nvme_env) {
        L4C_WARN("restore-sidecars: neither FitCache_DRAM_PATH nor "
                 "FitCache_NVME_PATH set; nothing to scan");
        return -1;
    }

    int total_restored = 0;

    auto restore_one = [&](bool to_dram) {
        return [&, to_dram](const std::string &cached_path,
                            const fitcache::fitcache_file_meta_v1 &meta) {
            std::unique_lock<std::shared_mutex> wlock(cache_mtx);
            path_cache_map[meta.original_path] = cached_path;
            if (to_dram) g_dram_used_bytes += meta.original_size;
            else         g_nvme_used_bytes += meta.original_size;
        };
    };

    if (dram_env && dram_env[0]) {
        int n = fitcache::meta_scan_tier_dir(dram_env, restore_one(true));
        if (n > 0) {
            L4C_INFO("restore-sidecars: restored %d files from DRAM tier %s",
                     n, dram_env);
            total_restored += n;
        }
    }
    if (nvme_env && nvme_env[0]) {
        int n = fitcache::meta_scan_tier_dir(nvme_env, restore_one(false));
        if (n > 0) {
            L4C_INFO("restore-sidecars: restored %d files from NVMe tier %s",
                     n, nvme_env);
            total_restored += n;
        }
    }
    L4C_INFO("restore-sidecars: total restored = %d", total_restored);
    return total_restored;
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
    
    L4C_INFO("FitCache_DRAM_PATH is set to %s", g_dram_path.c_str());
    L4C_INFO("FitCache_NVME_PATH is set to %s", g_nvme_path.c_str());
    L4C_INFO("FitCache_DRAM_CAPACITY is set to %llu", g_dram_capacity_bytes);
    L4C_INFO("FitCache_NVME_CAPACITY is set to %llu", g_nvme_capacity_bytes);

    queue<string> local_list;

    // string fsdax_base = string(fsdax_path) + "/XXXXXX";
    // string ssd_base   = string(ssd_path)   + "/XXXXXX";

    string dram_base = string(g_dram_path);
    string nvme_base   = string(g_nvme_path);

    while (1) {
        pthread_mutex_lock(&data_mutex);
        pthread_cond_wait(&data_cond, &data_mutex);
        
        int queue_size = data_queue.size();
        L4C_INFO("DEBUG: Data queue size: %d", queue_size);
        /* We can do stuff here when signaled */
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

            // Determine target tier by checking remaining capacity with file size
            bool to_dram = true;
            uint64_t file_size = 0;
            try {
                file_size = fs::file_size(original_path);
            } catch (const fs::filesystem_error &e) {
                L4C_ERR("Data mover: failed to stat %s: %s", original_path.c_str(), e.what());
                local_list.pop();
                continue;
            }

            if (g_dram_used_bytes + file_size <= g_dram_capacity_bytes) {
                to_dram = true;
            } else if (g_nvme_used_bytes + file_size <= g_nvme_capacity_bytes) {
                to_dram = false;
            } else {
                L4C_ERR("No space in DRAM or NVME to move file %s\n", original_path.c_str());
                local_list.pop();
                continue;
            }

            // Simple hash bucket implementation
            string basepath = to_dram ? dram_base : nvme_base;
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
                // Update the used bytes
                if(to_dram)
                {
                    g_dram_used_bytes += file_size;
                }
                else
                {
                    g_nvme_used_bytes += file_size;
                }
                if(DEBUG_HU)
                    L4C_INFO("Data mover: Copied %s -> %s using simple hash buckets", original_path.c_str(), filename.c_str());

                // Cross-job durability: write a sidecar so this cache survives
                // server restart and can be discovered by peer-job lookups.
                // Only meaningful in cross-job mode; in single-job mode the
                // sidecar is harmless extra metadata.
                if (fitcache::cross_job_enabled()) {
                    fitcache::fitcache_file_meta_v1 meta =
                        fitcache::meta_make_initial(
                            original_path,
                            file_size,
                            /*dataset_id_hash=*/0);  // TODO: wire dataset_id
                    if (fitcache::meta_write_sidecar(filename, meta) != 0) {
                        L4C_WARN("Data mover: failed to write sidecar for %s",
                                 filename.c_str());
                    } else if (DEBUG_HU) {
                        L4C_INFO("Data mover: wrote sidecar for %s",
                                 filename.c_str());
                    }
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
