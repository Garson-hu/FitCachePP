/**
 * fitcache_persistent_meta.h
 *
 * Per-cached-file sidecar metadata for cross-job durability.
 *
 * Every cached file at `${TIER_PATH}/<hh>/<hh>/<basename>` gets a sidecar
 * `${TIER_PATH}/<hh>/<hh>/<basename>.meta` containing the dataset_id hash,
 * original size + path, access counters, and a refcount of jobs currently
 * subscribing to the file.
 *
 * On server startup the tier directory tree is scanned; valid sidecars
 * rebuild g_fileMetaMap and path_cache_map so the cache survives server
 * restart and node reboot. This is what makes cross-job sharing more than
 * best-effort.
 *
 * On-disk format is little-endian fixed-layout (magic + version + uint64s
 * + a fixed-size original_path char buffer). Atomic write is "write to
 * .meta.tmp.<pid> + fsync + rename". Reads tolerate torn writes by
 * checking the magic + version; mismatches are treated as corrupted and
 * the file is quarantined (renamed .broken).
 *
 * Design ref: tpds_extension/02_design_cross_job.md, "Cache lifecycle and
 * reference counting" section.
 */

#ifndef FITCACHE_PERSISTENT_META_H
#define FITCACHE_PERSISTENT_META_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
#include <functional>
#include <string>
#include <vector>

namespace fitcache {

// On-disk sidecar layout. Fields are written / read in host byte order
// (single-cluster scope means we don't need endian portability).
constexpr uint32_t FITCACHE_META_MAGIC   = 0xF17CACE0u;
constexpr uint32_t FITCACHE_META_VERSION = 1u;
constexpr size_t   FITCACHE_META_PATH_MAX = 1024;

#pragma pack(push, 8)
struct fitcache_file_meta_v1 {
    uint32_t magic;                                // FITCACHE_META_MAGIC
    uint32_t version;                              // FITCACHE_META_VERSION
    uint64_t dataset_id_hash;                      // ties cached file to a dataset
    uint64_t original_size;                        // bytes
    uint64_t cached_at_unix;                       // when promotion completed
    uint64_t last_access_unix;                     // last read access
    uint32_t access_count;                         // total reads
    uint32_t refcount;                             // # of jobs currently subscribing
    char     original_path[FITCACHE_META_PATH_MAX];// PFS path, NUL-terminated
};
#pragma pack(pop)

// Atomically write a sidecar at `${cached_path}.meta`. Returns 0 on success,
// non-zero on I/O error. Tmp + rename guarantees no torn write is ever
// visible to readers.
int meta_write_sidecar(const std::string &cached_path,
                       const fitcache_file_meta_v1 &meta);

// Read the sidecar at `${cached_path}.meta`. Returns 0 on success and fills
// `out`. Returns -1 if the sidecar is missing, has wrong magic/version,
// or fails to parse — caller can decide whether to quarantine.
int meta_read_sidecar(const std::string &cached_path,
                      fitcache_file_meta_v1 *out);

// Walk a tier directory tree (e.g. ${FitCache_DRAM_PATH} or _NVME_PATH)
// looking for `*.meta` sidecars under any depth. For each valid sidecar,
// invoke `visitor(cached_path_without_meta_suffix, meta)`. Sidecars with
// wrong magic/version are renamed to `*.broken` and skipped (logged).
// Returns the count of valid sidecars visited; -1 on an unrecoverable
// directory error.
int meta_scan_tier_dir(
    const std::string &tier_root,
    const std::function<void(const std::string &cached_path,
                             const fitcache_file_meta_v1 &meta)> &visitor);

// Build a fresh sidecar struct for a freshly-cached file. Convenience
// wrapper over zero-initialise + populate; the caller still needs to call
// meta_write_sidecar to persist it.
fitcache_file_meta_v1 meta_make_initial(const std::string &original_path,
                                        uint64_t original_size,
                                        uint64_t dataset_id_hash);

// Bump the refcount on an existing sidecar. Reads, increments, writes
// atomically (flock-serialised). Returns the new refcount, or -1 on
// error (sidecar missing or corrupt).
int meta_bump_refcount(const std::string &cached_path);

// Decrement the refcount on an existing sidecar. Same atomicity as bump.
// Returns the new refcount, or -1 on error.
int meta_drop_refcount(const std::string &cached_path);

// Pick an eviction victim out of a candidate set. A cached path is evictable
// iff its sidecar exists, has valid magic+version, and refcount == 0.
// Returns the cached_path with the lowest access_count among evictable
// candidates, or "" if there is none. Caller is responsible for snapshotting
// the candidate list under whatever lock protects it.
std::string meta_select_eviction_victim(
    const std::vector<std::string> &cached_paths);

// Evict a single cached file: unlink the data file and its sidecar.
// Returns the bytes freed (original_size from the sidecar before unlinking)
// or 0 if the sidecar could not be read or the data file could not be
// unlinked. The caller still has to remove the cached_path from its in-memory
// path_cache_map.
uint64_t meta_evict_file(const std::string &cached_path);

}  // namespace fitcache

#endif  // __cplusplus

#endif  // FITCACHE_PERSISTENT_META_H
