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

// Warm-hit resolver for the direct-local-mmap path (2026-05-21 redesign).
// Computes the deterministic cached path for `original_path` in each local
// tier (FitCache_DRAM/PMEM/NVME_PATH) using the same std::hash<string> +
// two-level hash-bin scheme the server data mover uses, and checks whether a
// COMPLETE cached copy exists locally (cached file present AND its size
// equals the original PFS file's size). On a warm hit, writes the cached
// local path into `out` (up to outsz) and returns 1; on a miss returns 0.
// No RPC: resolution is purely client-side + local stat().
int fitcache_resolve_cached_path(const char *original_path,
                                 char *out, size_t outsz);

// Prefetch hint (TPDS prefetch-informed migration). The application calls this
// to declare a file it is about to mmap; FitCachePP forwards the hint to the
// owning server, which promotes the file ahead of the read. replication_mode
// follows fitcache_replication_mode_t (0 = unbounded = today's behavior).
// Returns 0 if the hint was sent, <0 on a bad path / no server. Non-blocking.
int fitcache_prefetch(const char *original_path, int replication_mode);

// ---------------------------------------------------------------------------
// Adaptive placement decision (TPDS adaptive caching, 2026-07).
// Chooses, at populate time, between the two placement strategies the system
// already implements: PARTITION_1X (each node prefetches only its owned 1/N
// slice; SINGLE_COPY) and REPLICATE_NX (every node caches the full dataset;
// UNBOUNDED). Inputs: the dataset file list, an optional per-file ownership
// hint, and the local cache budget observed at call time.
//   owned != NULL  -> the workload IS sample-partitionable (the loader can
//                     confine each node to a known subset): remote ratio r = 0,
//                     replication buys nothing -> PARTITION_1X.
//   owned == NULL  -> no partition exists (data-dependent access can touch any
//                     byte, e.g. a GNN gather): r -> 1, every non-local access
//                     is a PFS round-trip -> REPLICATE_NX iff the whole dataset
//                     fits the local budget; otherwise PARTITION_FALLBACK
//                     (prefetch nothing; the existing open-time cache-on-miss
//                     path caches the hot set up to capacity and overflow reads
//                     fall through to the PFS).
// The call is pure decision + one stat() per file; it performs no RPC and no
// data movement. decide_us reports its own wall time (the paper's overhead
// number).
enum {
    FITCACHE_PLACE_PARTITION_1X   = 0,
    FITCACHE_PLACE_REPLICATE_NX   = 1,
    FITCACHE_PLACE_PART_FALLBACK  = 2,  // un-partitionable but capacity-blocked
};

typedef struct fitcache_adaptive_decision {
    int      mode;             // FITCACHE_PLACE_*
    int      replication_mode; // value to pass to fitcache_prefetch()
    uint64_t dataset_bytes;    // total bytes across `paths`
    uint64_t owned_bytes;      // bytes of the owned subset (== dataset_bytes if owned==NULL)
    uint64_t budget_bytes;     // usable local-cache budget observed at decision time
    double   decide_us;        // wall time of this call (scan + policy)
} fitcache_adaptive_decision_t;

// paths: npaths dataset file paths. owned: per-file 0/1 ownership flags for
// THIS node under the app's partition, or NULL if no partition exists.
// Returns 0 and fills *out on success; <0 on bad args / unreadable dataset.
int fitcache_adaptive_decide(const char *const *paths, const int *owned,
                             int npaths, fitcache_adaptive_decision_t *out);

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