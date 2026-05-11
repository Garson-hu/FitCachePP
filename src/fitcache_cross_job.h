/**
 * fitcache_cross_job.h
 *
 * Cross-job sharing primitives: rendezvous (HRW) routing and peer-job lookup.
 *
 * Routing in single-job IPDPS mode is `hash(path) % SERVER_COUNT`. That breaks
 * across jobs that have different server counts, so under cross-job mode we
 * route via highest-random-weight (HRW) hashing over the live server set
 * advertised in the cluster registry.
 *
 * Design ref: tpds_extension/02_design_cross_job.md, "Routing under variable
 * server-count" and "Open / Read flow under cross-job mode" sections.
 */

#ifndef FITCACHE_CROSS_JOB_H
#define FITCACHE_CROSS_JOB_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
#include <string>
#include <vector>

namespace fitcache {

// One server endpoint as seen by the routing layer.
// Populated either from the local job's .ports.cfg.* file (single-job mode)
// or from the cluster registry (cross-job mode).
struct ServerEndpoint {
    int         rank;            // job-local rank (or registry-global rank)
    std::string addr;            // mercury address string
    std::string node_uuid;       // stable per-node identifier
    std::string jobid;           // owning job (informational; "" = local)
    bool        live;            // heartbeat-fresh
};

// Highest-random-weight hashing.
// Returns the index into `servers` whose (path, server) hash is largest.
// Returns -1 if `servers` is empty.
//
// xxh-style scoring via fitcache_fnv1a64 of (path || node_uuid || rank).
int hrw_select(const std::string &path,
               const std::vector<ServerEndpoint> &servers);

// Backwards-compatible modulo routing (IPDPS behaviour).
// Equivalent to `hash(path) % server_count`.
int modulo_select(const std::string &path, int server_count);

// Returns true iff cross-job mode is enabled via env var FitCache_CROSS_JOB=1.
// Cached on first call.
bool cross_job_enabled();

// Pick a server for `path`. Returns a routing slot consumable by
// fitcache_client_comm_lookup_addr.
//
// Single-job mode (cross_job_enabled() == false): returns
//   modulo_select(path, local_server_count). The slot maps to a job-local
//   rank resolved from .ports.cfg.${SLURM_JOBID}.
//
// Cross-job mode: refreshes the cluster live-server snapshot (with a small
//   in-process TTL), runs HRW over the live set, and returns a slot whose
//   addr is registered in the per-process cluster endpoint table. The slot
//   is also stable for repeated calls on the same path while the live set
//   is unchanged.
//
// On any failure (registry empty, IO error), falls back to modulo so that
// the call always returns a usable slot.
int select_server_for_path(const std::string &path, int local_server_count);

// Resolve a routing slot returned by select_server_for_path() to a Mercury
// addr string. Only meaningful for slots issued in cross-job mode; returns
// an empty string for unknown slots so callers can fall back to single-job
// (.ports.cfg) lookup.
std::string slot_to_addr(int slot);

// Force a refresh of the cluster endpoint table. Mainly useful for tests;
// production code refreshes opportunistically inside select_server_for_path.
void refresh_cluster_endpoints();

// Register a Mercury addr as a routing slot if it isn't already known, and
// return the slot id (existing or newly-issued). Used by the client when an
// open RPC returns FITCACHE_OPEN_REDIRECT pointing at a peer addr that may
// not yet be in the cluster snapshot. Returns -1 on empty input.
int register_endpoint(const std::string &addr);

}  // namespace fitcache

#endif  // __cplusplus

#endif  // FITCACHE_CROSS_JOB_H
