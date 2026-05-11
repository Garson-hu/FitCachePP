/**
 * fitcache_dataset_id.h
 *
 * Dataset identity for cross-job cache sharing.
 *
 * A "dataset" is the unit of identity that gates trust between FitCache jobs.
 * A cached file inherits its dataset's identity. Two jobs may share a cached
 * file iff their dataset_id matches (see fitcache_dataset_id_eq).
 *
 * Design ref: tpds_extension/02_design_cross_job.md, "Dataset identity"
 * section.
 */

#ifndef FITCACHE_DATASET_ID_H
#define FITCACHE_DATASET_ID_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
#include <string>
extern "C" {
#endif

#define FITCACHE_DATASET_NAME_MAX 64

typedef struct fitcache_dataset_id {
    char     name[FITCACHE_DATASET_NAME_MAX]; // human-readable, e.g. "cosmoUniverse-v1"
    uint64_t root_path_hash;                  // FNV-1a of canonical(FitCache_DATA_DIR)
    uint64_t manifest_hash;                   // hash of (sorted paths || sizes || mtimes)
    uint64_t content_fingerprint;             // optional sampled-content hash, 0 if disabled
    uint32_t version;                         // bumped when manifest_hash changes
} fitcache_dataset_id_t;

// Stable 64-bit hash for cross-process consistency (FNV-1a).
uint64_t fitcache_fnv1a64(const void *buf, size_t len);

// Compute root_path_hash from a canonical path string.
uint64_t fitcache_dataset_root_path_hash(const char *canonical_root);

// Equality predicate for sharing eligibility (see the "Sharing predicate"
// subsection of the dataset-identity design in
// tpds_extension/02_design_cross_job.md).
int fitcache_dataset_id_eq(const fitcache_dataset_id_t *a,
                           const fitcache_dataset_id_t *b);

// Hex-encode dataset id to a fixed-size string buffer (for filenames + logs).
// Buffer must be at least 33 bytes (32 hex chars + NUL).
void fitcache_dataset_id_to_hex(const fitcache_dataset_id_t *id,
                                char *out_hex, size_t out_len);

#ifdef __cplusplus
}  // extern "C"

namespace fitcache {

// Build a dataset_id by scanning the dataset root directory and computing
// the manifest hash from sorted (path, size, mtime) tuples.
//
// Honors caching: if `${root}/.fitcache_dataset.v1` exists and its embedded
// root mtime matches the directory's mtime, the cached descriptor is reused.
//
// If sample_count > 0, also compute content_fingerprint over `sample_count`
// pseudo-randomly selected files (xxh-style sampling).
fitcache_dataset_id_t build_dataset_id(const std::string &root_path,
                                       const std::string &dataset_name,
                                       int sample_count);

}  // namespace fitcache

#endif

#endif  // FITCACHE_DATASET_ID_H
