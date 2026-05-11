#ifndef FitCache_MULTI_SOURCE_READ_H
#define FitCache_MULTI_SOURCE_READ_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>

// C-safe entry point. The wrappers.c LD_PRELOAD shim includes this header
// to call ms_read; the cluster code links the C++ implementation in
// fitcache_multi_source_read.cpp.
#ifdef __cplusplus
extern "C" {
#endif

ssize_t ms_read(int fd, void* buf, size_t count, int64_t offset);

// A structure to hold the asynchronous state for the multi-source read.
// Visible to wrappers.c (via this header) only as an opaque struct; only
// the C++ implementation accesses its fields.
struct ms_read_state {
    pthread_mutex_t      lock;
    pthread_cond_t       cond;
    bool                 completed;
    bool                 pm_done;
    bool                 ssd_done;
    ssize_t              pm_result;
    ssize_t              ssd_result;
};

#ifdef __cplusplus
}  // close extern "C"

// C++-only declarations. Kept out of the extern "C" block because they use
// std::vector. Including this header from a C TU still works because the
// __cplusplus guard skips this section.
#include <vector>
extern std::vector<int> g_pm_ranks;   // DRAM ranks
extern std::vector<int> g_ssd_ranks;  // NVME ranks
#endif

#endif  // FitCache_MULTI_SOURCE_READ_H