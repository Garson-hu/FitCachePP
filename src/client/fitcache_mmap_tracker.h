/**
 * fitcache_mmap_tracker.h
 *
 * Bookkeeping for mmap mappings that the FitCache LD_PRELOAD client has
 * redirected away from the kernel's file-backed page-fault path. The
 * mmap-on-tracked-fd path can't return the kernel's file-backed VMA,
 * because then page faults would bypass FitCache entirely (see
 * benchmarks/results/arc/workload_generalization/megatron_mmap_limitation.md
 * for the original failure mode). Instead the wrapper allocates an
 * anonymous mapping, populates it via the existing FitCache read path,
 * and records (addr -> length) here so that munmap on the user's addr
 * can unmap the right region.
 *
 * The map is intentionally tiny — only mappings WE created, not every
 * mmap the process does. Lookups are short-array scans rather than a
 * full unordered_map to keep the dependency footprint inside the
 * LD_PRELOAD'd .so minimal.
 */

#ifndef FITCACHE_MMAP_TRACKER_H
#define FITCACHE_MMAP_TRACKER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Record that the wrapper allocated an anonymous mapping of `length`
 * bytes at `addr` to satisfy an mmap on a FitCache-tracked fd.
 */
void fitcache_mmap_tracker_record(void *addr, size_t length);

/**
 * Look up the length of a FitCache-allocated mapping at `addr`. Returns
 * 0 if `addr` was not produced by the FitCache wrapper (the caller should
 * delegate to the real munmap with the original length argument).
 */
size_t fitcache_mmap_tracker_lookup(void *addr);

/**
 * Drop the tracking entry for `addr`. No-op if there isn't one.
 */
void fitcache_mmap_tracker_drop(void *addr);

#ifdef __cplusplus
}
#endif

#endif  // FITCACHE_MMAP_TRACKER_H
