#pragma once
#ifndef __FitCache_DATA_MOVER_INTERNAL_H__
#define __FitCache_DATA_MOVER_INTERNAL_H__

#include <atomic>
#include <queue>
#include <map>

#include <unordered_map>
#include <shared_mutex>
#include <mutex>
/*Data Mover */

#ifdef FitCache_SERVER
extern pthread_cond_t data_cond;
extern pthread_mutex_t data_mutex;
extern std::queue<std::string> data_queue;

extern std::unordered_map<int, std::string> fd_to_path;
extern std::unordered_map<std::string, std::string> path_cache_map;

extern std::shared_mutex cache_mtx;

#endif


void *fitcache_data_mover_fn(void *args);

// Cross-job durability: scan FitCache_DRAM_PATH + FitCache_NVME_PATH for
// valid `*.meta` sidecars and rebuild path_cache_map + g_dram_used_bytes /
// g_nvme_used_bytes accordingly. Called from the server startup path when
// FitCache_CROSS_JOB=1 so a restarted server can immediately serve any
// cache that survived its previous death (and so peer-job lookups against
// it return has=1 instead of has=0).
//
// Returns the number of files restored (0 on first-ever start; -1 on env
// misconfiguration).
int fitcache_data_mover_restore_from_sidecars();

// Background eviction reaper thread entry point. Wakes every
// FitCache_REAPER_SEC seconds (default 30) and, for each tier whose used
// bytes exceeds FitCache_EVICT_HIGH_WM * capacity, evicts refcount=0 files
// (lowest access_count first) until used bytes drops below
// FitCache_EVICT_LOW_WM * capacity. Only active under FitCache_CROSS_JOB=1
// because it relies on sidecars (which are only written in cross-job mode).
// Set fitcache_eviction_reaper_running to false and pthread_join to stop it.
void *fitcache_eviction_reaper_fn(void *arg);
extern std::atomic<bool> fitcache_eviction_reaper_running;

#endif //__FitCache_DATA_MOVER_INTERNAL_H__