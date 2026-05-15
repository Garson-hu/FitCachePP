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

// Subscriber-lease management for cross-job sharing. The design doc proposed
// these as Mercury RPCs (fitcache_subscribe_rpc / fitcache_release_rpc); the
// implementation collapses them into direct PFS-backed registry writes
// because the registry is already PFS-backed and the client links the
// cluster_registry module — adding an RPC layer would only add latency and
// failure modes for no semantic gain. The wire-level subscribe/release RPCs
// can still be added later if a client ever needs to subscribe without PFS
// write access.
//
// subscribe_self_to_local_dataset: idempotent. Computes a lightweight
// dataset_id from FitCache_DATA_DIR (root-path hash; full manifest scan is
// deferred), initialises the registry if needed, and inserts a subscriber
// record with a lease running for FitCache_LEASE_RENEW_SEC * 2 seconds.
//
// release_self_from_local_dataset: idempotent. Removes the subscriber record
// inserted by the matching subscribe call.
//
// Both no-op when cross_job_enabled() is false, so single-job (IPDPS) builds
// remain bit-identical.
void subscribe_self_to_local_dataset();
void release_self_from_local_dataset();

// Refresh this process's subscriber lease in the registry, extending its
// lease_until to now + FitCache_LEASE_RENEW_SEC * 2. No-op if the process
// never called subscribe_self (or cross-job mode is off). Called from the
// server heartbeat thread; long-running training jobs need the periodic
// extension because the initial lease only covers ~2 * renew_sec from
// startup, after which subscriber-GC could prune the entry mid-run.
void renew_self_dataset_lease();

// Read this process's dataset_id manifest_hash (computed by
// subscribe_self_to_local_dataset via build_dataset_id). Returns 0 if the
// process never subscribed. The data mover passes this into sidecar writes
// so the on-disk metadata records the dataset the cached file belongs to —
// preventing a future restored server from associating a sidecar with the
// wrong dataset (and also enabling the design-doc "refuse sharing between
// jobs whose datasets diverged" check downstream).
uint64_t get_self_dataset_manifest_hash();

// Cross-job telemetry counters. Bumped from the server's open + peer-lookup
// code paths so that experiments can verify which paths actually fired
// (vs. were merely defined). Log periodically from the heartbeat thread
// and once at server shutdown via log_cross_job_stats().
struct CrossJobCounters {
    uint64_t opens_total;             // every fitcache_open_rpc_handler entry
    uint64_t opens_local_hit;         // path was already in path_cache_map
    uint64_t opens_redirect_to_peer;  // peer-lookup returned has=1; redirected
    uint64_t opens_pfs_fallback;      // open returned via PFS path (no peer)
    uint64_t peer_lookup_forwarded;   // outgoing peer_lookup_rpc HG_Forward OK
    uint64_t peer_lookup_handled;     // incoming peer_lookup_rpc handler entry
    uint64_t peer_lookup_has_yes;     // peer handler returned has=1
    uint64_t peer_lookup_has_no;      // peer handler returned has=0
};

// Read a snapshot of the counters (no internal locking — values are atomic
// but the snapshot is non-atomic with respect to in-flight increments, which
// is fine for logging).
CrossJobCounters cross_job_counters_snapshot();

// Per-event bump helpers. Cheap (one atomic increment); safe to call from
// any thread including Mercury handler threads.
void cross_job_counter_bump_opens_total();
void cross_job_counter_bump_opens_local_hit();
void cross_job_counter_bump_opens_redirect_to_peer();
void cross_job_counter_bump_opens_pfs_fallback();
void cross_job_counter_bump_peer_lookup_forwarded();
void cross_job_counter_bump_peer_lookup_handled();
void cross_job_counter_bump_peer_lookup_has_yes();
void cross_job_counter_bump_peer_lookup_has_no();

// Emit one L4C_INFO line summarising the counters. Includes a delta vs. the
// previous call so periodic logging shows recent activity, not just the
// cumulative total. The first call shows totals only (no delta available).
// `server_rank` is informational so cluster experiments can grep per-server.
void log_cross_job_stats(int server_rank);

}  // namespace fitcache

#endif  // __cplusplus

#endif  // FITCACHE_CROSS_JOB_H
