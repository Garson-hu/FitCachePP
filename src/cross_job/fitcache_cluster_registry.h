/**
 * fitcache_cluster_registry.h
 *
 * PFS-backed cluster registry for cross-job server discovery.
 *
 * The IPDPS code uses .ports.cfg.${SLURM_JOBID} for job-local discovery. That
 * stays unchanged. This module adds a parallel cluster-scoped registry that
 * lets jobs see each other's FitCache servers.
 *
 * Storage layout (PFS-backed):
 *   ${FitCache_CLUSTER_REGISTRY_DIR}/registry.v1/
 *     nodes/<hostname>.txt       - one entry per node, flock-protected
 *     datasets/<dsid_hex>.txt    - per-dataset subscriber list
 *
 * On registry I/O failure, callers must fall back to single-job behavior.
 *
 * Design ref: tpds_extension/02_design_cross_job.md, "Cluster registry"
 * section.
 */

#ifndef FITCACHE_CLUSTER_REGISTRY_H
#define FITCACHE_CLUSTER_REGISTRY_H

#include <stdint.h>

#ifdef __cplusplus
#include <string>
#include <vector>

#include "fitcache_cross_job.h"   // ServerEndpoint
#include "fitcache_dataset_id.h"  // fitcache_dataset_id_t

namespace fitcache {

// Initialize the cluster registry. Reads FitCache_CLUSTER_REGISTRY_DIR
// (or derives a default from FitCache_DATA_DIR), creates the directory tree
// if missing. Returns 0 on success, non-zero if registry cannot be used
// (caller should fall back to single-job mode).
int registry_init();

// Register this server in the per-node entry. Idempotent: existing entries
// for this (jobid, rank) are overwritten.
int registry_register_server(const ServerEndpoint &self);

// Update only the heartbeat timestamp for this server. Cheap; called every
// FitCache_HEARTBEAT_SEC.
int registry_heartbeat(int rank);

// Remove this server's entry on graceful shutdown.
int registry_deregister_server(int rank);

// Subscribe this job to a dataset (records us as an active reader and bumps
// refcount on cached files for that dataset).
int registry_subscribe_dataset(const fitcache_dataset_id_t &id,
                               uint32_t jobid,
                               uint64_t lease_until_unix);

// Release subscription on graceful job shutdown.
int registry_release_dataset(const fitcache_dataset_id_t &id,
                             uint32_t jobid);

// Read the live server set across the whole cluster (filtered by liveness).
// Used by the client at routing time when cross_job mode is on.
std::vector<ServerEndpoint> registry_live_servers();

// Read which nodes have cached files for a given dataset.
// Empty vector if dataset is unknown to the registry.
std::vector<std::string> registry_nodes_caching_dataset(
    const fitcache_dataset_id_t &id);

// Garbage-collect stale entries (heartbeat older than 3x heartbeat interval).
// Safe to call from a background reaper thread.
int registry_gc_stale();

// ----------------------------------------------------------------------------
// Per-file presence index (Option 1 of the cross-job has_yes=0 fix).
//
// Pure PFS-backed: when a FitCache server finishes copying file X into its
// local DRAM/NVMe tier, it calls registry_record_file_presence(X, my_addr).
// The presence record is durable across server restarts and visible to peer
// servers' peer_lookup_rpc_handler, which calls registry_lookup_file_presence
// to find ANY rank in the cluster currently holding the file.
//
// Storage layout under ${registry.v1}/presence/:
//   <bucket1>/<bucket2>/<sha1_hex_full>.txt
// (two-level bucketing: a/b/<hash>.txt where a = first 2 hex chars,
//  b = next 2 hex chars; balances directory entry counts on Lustre/BeeGFS.)
//
// File format: one line per (server_addr, timestamp) tuple, tab-separated:
//   <addr>\t<unix_ts>\t<dataset_manifest_hash>\n
// Multiple writers append; readers parse + dedupe by addr keeping latest ts.
// Stale entries (ts older than presence_stale_sec()) are filtered out at read
// time without rewriting the file (lazy GC via registry_gc_file_presence).
//
// No flock: the only writer for any (path, addr) pair is the one server
// instance with that addr, and we append-only with a single write() call
// shorter than PIPE_BUF (4096 bytes) so the kernel atomicity guarantee
// applies. Readers tolerate truncated last lines (parse_presence_line is
// strict and silently drops malformed entries).

// Record that the calling server now caches `path`. `addr` is this server's
// Mercury address string (the one that peers should redirect clients to in
// order to fetch the file). `dataset_manifest_hash` is the dataset id of the
// file (0 = unknown / single-job mode). Returns 0 on success, -1 on PFS
// failure. Safe to call concurrently from any thread.
int registry_record_file_presence(const std::string &path,
                                  const std::string &addr,
                                  uint64_t dataset_manifest_hash);

// One entry returned by registry_lookup_file_presence.
struct FilePresenceHolder {
    std::string addr;                    // Mercury addr of the holding server
    uint64_t    last_seen_unix;          // most-recent record timestamp
    uint64_t    dataset_manifest_hash;   // recorded at insertion time
};

// Look up which servers currently have `path` cached. Returns an empty vector
// if no one has registered presence for the path (or PFS read failed).
// `max_age_sec` is the staleness cutoff — entries older than this are filtered
// out (default: presence_stale_sec()).
std::vector<FilePresenceHolder> registry_lookup_file_presence(
    const std::string &path, uint64_t max_age_sec = 0);

// Garbage-collect stale presence entries by rewriting each presence file with
// only fresh entries. Bounded — scans at most `max_files` files per call so a
// background invocation never blocks on a million-file dataset. Returns the
// number of files rewritten.
int registry_gc_file_presence(int max_files = 256);

// Internal helper: stale cutoff in seconds. Read from
// FitCache_PRESENCE_STALE_SEC on first call; defaults to 180s (3x heartbeat).
uint64_t presence_stale_sec();

}  // namespace fitcache

#endif  // __cplusplus

#endif  // FITCACHE_CLUSTER_REGISTRY_H
