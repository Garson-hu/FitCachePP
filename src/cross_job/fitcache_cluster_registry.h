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

}  // namespace fitcache

#endif  // __cplusplus

#endif  // FITCACHE_CLUSTER_REGISTRY_H
