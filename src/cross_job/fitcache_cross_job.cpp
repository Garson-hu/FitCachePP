/**
 * fitcache_cross_job.cpp
 *
 * See fitcache_cross_job.h for the public contract.
 *
 * HRW score: FNV-1a 64-bit over the concatenation
 *   path || '\x00' || node_uuid || '\x00' || rank
 *
 * The NUL separators prevent collision between e.g.
 *   ("foo", "bar1") vs ("foob", "ar1").
 *
 * Design ref: tpds_extension/02_design_cross_job.md, "Routing under variable
 * server-count" section.
 */

#include "fitcache_cross_job.h"
#include "fitcache_cluster_registry.h"
#include "fitcache_dataset_id.h"  // fitcache_fnv1a64

extern "C" {
#include "fitcache_logging.h"
#include <unistd.h>            // getpid()
}

#include <atomic>
#include <ctime>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>
#include <vector>

namespace fitcache {

int hrw_select(const std::string &path,
               const std::vector<ServerEndpoint> &servers) {
    if (servers.empty()) return -1;

    int best_idx = -1;
    uint64_t best_score = 0;

    for (size_t i = 0; i < servers.size(); ++i) {
        const ServerEndpoint &s = servers[i];
        if (!s.live) continue;

        // Score = FNV-1a(path || NUL || node_uuid || NUL || rank || NUL || addr).
        // The Mercury addr is included alongside node_uuid + rank because
        // some clusters (e.g. ARC c70 + c71) ship cloned VM images with
        // identical /etc/machine-id, which makes node_uuid identical across
        // hosts. Without addr in the hash, (node_uuid, rank) ties between
        // hosts collapsed all paths onto whichever host's slot was iterated
        // first — c71's servers got no work in the two-job concurrent
        // benchmark on c70 + c71. Including addr (which IS unique per
        // Mercury endpoint, since it embeds host:port) breaks the ties and
        // restores HRW's intended ~1/N load balance.
        const uint64_t FNV_OFFSET = 0xcbf29ce484222325ULL;
        const uint64_t FNV_PRIME  = 0x100000001b3ULL;
        uint64_t h = FNV_OFFSET;

        for (char c : path) { h ^= static_cast<uint64_t>(c); h *= FNV_PRIME; }
        h ^= 0; h *= FNV_PRIME;
        for (char c : s.node_uuid) { h ^= static_cast<uint64_t>(c); h *= FNV_PRIME; }
        h ^= 0; h *= FNV_PRIME;

        uint32_t r = static_cast<uint32_t>(s.rank);
        for (int b = 0; b < 4; ++b) {
            h ^= static_cast<uint64_t>((r >> (b * 8)) & 0xff);
            h *= FNV_PRIME;
        }
        h ^= 0; h *= FNV_PRIME;
        for (char c : s.addr) { h ^= static_cast<uint64_t>(c); h *= FNV_PRIME; }

        if (best_idx < 0 || h > best_score) {
            best_score = h;
            best_idx   = static_cast<int>(i);
        }
    }
    return best_idx;
}

int modulo_select(const std::string &path, int server_count) {
    if (server_count <= 0) return -1;
    uint64_t h = fitcache_fnv1a64(path.data(), path.size());
    return static_cast<int>(h % static_cast<uint64_t>(server_count));
}

bool cross_job_enabled() {
    static int cached = -1;
    if (cached < 0) {
        const char *v = std::getenv("FitCache_CROSS_JOB");
        cached = (v && std::strcmp(v, "1") == 0) ? 1 : 0;
        L4C_INFO("cross_job_enabled: FitCache_CROSS_JOB=%s -> %s",
                 v ? v : "(unset)", cached ? "ON" : "OFF");
    }
    return cached != 0;
}

bool persist_meta_enabled() {
    // Sidecar metadata persistence (write-on-promote + restore-on-startup).
    // Decoupled from cross_job_enabled() so single-job runs can opt in to
    // cache durability across server restart without engaging the cross-job
    // registry / peer-lookup / sibling-refresh machinery (which adds
    // background threads and per-call latency that skewed Horovod ranks at
    // n=32768/1N in 2026-05-18 testing).
    //
    // Auto-on when cross_job_enabled() is true (cross-job mode needs the
    // sidecars for peer discovery anyway); otherwise opt-in via
    // FitCache_PERSIST_META=1.
    static int cached = -1;
    if (cached < 0) {
        const char *v = std::getenv("FitCache_PERSIST_META");
        int explicit_on = (v && std::strcmp(v, "1") == 0) ? 1 : 0;
        cached = (explicit_on || cross_job_enabled()) ? 1 : 0;
        L4C_INFO("persist_meta_enabled: FitCache_PERSIST_META=%s cross_job=%s -> %s",
                 v ? v : "(unset)", cross_job_enabled() ? "ON" : "OFF",
                 cached ? "ON" : "OFF");
    }
    return cached != 0;
}

// Default peer-RPC deadline for the open-time peer_lookup fanout. Picked at
// the upper end of expected steady-state RPC latency (single-digit ms on
// Frontier Slingshot) so legitimate slow responses don't hit the watchdog,
// but well below a SLURM job's wall-clock so a single dead peer can't
// indefinitely block another job's training run.
static constexpr int kDefaultPeerRpcTimeoutSec = 30;

int peer_rpc_timeout_sec() {
    static int cached = -2;  // sentinel: -2 = not read; -1 = disabled; >=0 = value
    if (cached == -2) {
        const char *v = std::getenv("FitCache_PEER_RPC_TIMEOUT_SEC");
        if (!v) {
            cached = kDefaultPeerRpcTimeoutSec;
        } else {
            int n = std::atoi(v);
            cached = (n >= 0) ? n : kDefaultPeerRpcTimeoutSec;
        }
        L4C_INFO("peer_rpc_timeout_sec: FitCache_PEER_RPC_TIMEOUT_SEC=%s -> %d sec %s",
                 v ? v : "(unset)", cached,
                 cached == 0 ? "(watchdog DISABLED)" : "");
    }
    return cached;
}

// ----------------------------------------------------------------------------
// Cluster endpoint table for cross-job routing.
//
// `g_endpoints` is the permanent slot table — once a (addr) is seen, it gets
// a stable slot id forever (never compacted) so that lookup_addr lookups
// remain valid for the lifetime of the process. `g_live_slots` is the
// currently-live subset (snapshot of the registry) used as the HRW input.
//
// Both are guarded by g_routing_mtx. Refresh cadence is bounded by
// kRefreshIntervalSec to avoid hammering PFS on every routing decision.
// ----------------------------------------------------------------------------
namespace {

constexpr uint64_t kRefreshIntervalSec = 5;

std::mutex                              g_routing_mtx;
std::vector<ServerEndpoint>             g_endpoints;       // slot -> endpoint
std::unordered_map<std::string, int>    g_addr_to_slot;
std::vector<int>                        g_live_slots;
uint64_t                                g_last_refresh_unix = 0;

uint64_t now_unix() { return static_cast<uint64_t>(std::time(nullptr)); }

// Caller must hold g_routing_mtx.
void refresh_locked() {
    std::vector<ServerEndpoint> live = registry_live_servers();
    g_live_slots.clear();
    for (auto &s : live) {
        if (!s.live || s.addr.empty()) continue;
        auto it = g_addr_to_slot.find(s.addr);
        int slot;
        if (it == g_addr_to_slot.end()) {
            slot = static_cast<int>(g_endpoints.size());
            g_endpoints.push_back(s);
            g_addr_to_slot.emplace(s.addr, slot);
        } else {
            slot = it->second;
            g_endpoints[slot] = s;  // refresh node_uuid/jobid/heartbeat
        }
        g_live_slots.push_back(slot);
    }
    g_last_refresh_unix = now_unix();
}

}  // namespace

void refresh_cluster_endpoints() {
    std::lock_guard<std::mutex> lock(g_routing_mtx);
    refresh_locked();
}

int select_server_for_path(const std::string &path, int local_server_count) {
    if (!cross_job_enabled()) {
        return modulo_select(path, local_server_count);
    }

    std::lock_guard<std::mutex> lock(g_routing_mtx);
    uint64_t now = now_unix();
    if (g_live_slots.empty() || now - g_last_refresh_unix >= kRefreshIntervalSec) {
        refresh_locked();
    }
    if (g_live_slots.empty()) {
        // Registry empty or unreadable. Degrade to modulo so the call returns
        // a usable slot. Single-job .ports.cfg path resolves it; otherwise
        // the open will fail-fast via the lookup_addr signal.
        return modulo_select(path, local_server_count);
    }

    // Build the HRW input from the currently-live slot subset.
    std::vector<ServerEndpoint> view;
    view.reserve(g_live_slots.size());
    for (int s : g_live_slots) view.push_back(g_endpoints[s]);

    int idx = hrw_select(path, view);
    if (idx < 0) return modulo_select(path, local_server_count);
    return g_live_slots[idx];
}

std::string slot_to_addr(int slot) {
    std::lock_guard<std::mutex> lock(g_routing_mtx);
    if (slot < 0 || static_cast<size_t>(slot) >= g_endpoints.size()) return {};
    return g_endpoints[slot].addr;
}

int register_endpoint(const std::string &addr) {
    if (addr.empty()) return -1;
    std::lock_guard<std::mutex> lock(g_routing_mtx);
    auto it = g_addr_to_slot.find(addr);
    if (it != g_addr_to_slot.end()) return it->second;
    ServerEndpoint s;
    s.rank      = -1;       // unknown — we only have the addr
    s.addr      = addr;
    s.node_uuid = "";
    s.jobid     = "";
    s.live      = true;
    int slot = static_cast<int>(g_endpoints.size());
    g_endpoints.push_back(s);
    g_addr_to_slot.emplace(s.addr, slot);
    return slot;
}

// ----------------------------------------------------------------------------
// Subscriber-lease management.
// State for the (one) subscription this process holds. A process subscribes
// at most once — to the dataset referenced by FitCache_DATA_DIR.
// ----------------------------------------------------------------------------
namespace {

std::mutex            g_subscribe_mtx;
fitcache_dataset_id_t g_self_dataset_id;
bool                  g_self_subscribed = false;
uint32_t              g_self_jobid      = 0;

uint32_t derive_jobid() {
    if (const char *v = std::getenv("SLURM_JOBID")) {
        int n = std::atoi(v);
        if (n > 0) return static_cast<uint32_t>(n);
    }
    return static_cast<uint32_t>(getpid());
}

uint64_t derive_lease_until() {
    int renew_sec = 300;
    if (const char *v = std::getenv("FitCache_LEASE_RENEW_SEC")) {
        int n = std::atoi(v);
        if (n > 0) renew_sec = n;
    }
    return static_cast<uint64_t>(std::time(nullptr)) + static_cast<uint64_t>(renew_sec) * 2;
}

}  // namespace

void subscribe_self_to_local_dataset() {
    if (!cross_job_enabled()) return;
    std::lock_guard<std::mutex> lock(g_subscribe_mtx);
    if (g_self_subscribed) return;

    const char *data_dir = std::getenv("FitCache_DATA_DIR");
    if (!data_dir || !data_dir[0]) {
        L4C_WARN("subscribe-self: FitCache_DATA_DIR not set; cannot subscribe");
        return;
    }
    if (registry_init() != 0) {
        L4C_WARN("subscribe-self: registry_init failed; not subscribing");
        return;
    }

    // Full dataset_id: root_path_hash AND a manifest_hash derived from the
    // sorted (path, size, mtime) tuples under data_dir. This is what the
    // design-doc cross-job-sharing protocol needs to refuse sharing between
    // jobs whose datasets have diverged (e.g. one has extra training files
    // the other doesn't). build_dataset_id caches the manifest scan on disk
    // (`<data_dir>/.fitcache_dataset.v1`) so the cost is paid once per
    // startup and reused across subsequent processes.
    g_self_dataset_id = fitcache::build_dataset_id(
        data_dir, "fitcache-default", /*sample_count=*/0);
    // If build_dataset_id produced an all-zero result (e.g. data_dir didn't
    // exist or scan failed), fall back to the lightweight root_path_hash so
    // the subscribe call still has something usable.
    if (g_self_dataset_id.root_path_hash == 0) {
        std::memset(&g_self_dataset_id, 0, sizeof(g_self_dataset_id));
        std::strncpy(g_self_dataset_id.name, "fitcache-default",
                     sizeof(g_self_dataset_id.name) - 1);
        g_self_dataset_id.root_path_hash = fitcache_dataset_root_path_hash(data_dir);
        g_self_dataset_id.manifest_hash  = g_self_dataset_id.root_path_hash;
    }

    g_self_jobid = derive_jobid();
    uint64_t lease_until = derive_lease_until();

    int rc = registry_subscribe_dataset(g_self_dataset_id, g_self_jobid, lease_until);
    if (rc == 0) {
        g_self_subscribed = true;
        L4C_INFO("subscribe-self: subscribed (root_hash=0x%lx, jobid=%u, "
                 "lease_until=%lu)",
                 (unsigned long)g_self_dataset_id.root_path_hash,
                 g_self_jobid, (unsigned long)lease_until);
    } else {
        L4C_WARN("subscribe-self: registry_subscribe_dataset failed (rc=%d)", rc);
    }
}

uint64_t get_self_dataset_manifest_hash() {
    std::lock_guard<std::mutex> lock(g_subscribe_mtx);
    return g_self_subscribed ? g_self_dataset_id.manifest_hash : 0;
}

void renew_self_dataset_lease() {
    if (!cross_job_enabled()) return;
    std::lock_guard<std::mutex> lock(g_subscribe_mtx);
    if (!g_self_subscribed) return;   // nothing to renew

    uint64_t new_lease_until = derive_lease_until();
    int rc = registry_subscribe_dataset(g_self_dataset_id, g_self_jobid, new_lease_until);
    if (rc == 0) {
        L4C_INFO("renew-self: extended subscriber lease (jobid=%u, lease_until=%lu)",
                 g_self_jobid, (unsigned long)new_lease_until);
    } else {
        L4C_WARN("renew-self: registry_subscribe_dataset failed (rc=%d) — lease may expire", rc);
    }
}

void release_self_from_local_dataset() {
    std::lock_guard<std::mutex> lock(g_subscribe_mtx);
    if (!g_self_subscribed) return;
    int rc = registry_release_dataset(g_self_dataset_id, g_self_jobid);
    if (rc == 0) {
        L4C_INFO("release-self: released subscription (jobid=%u)", g_self_jobid);
    } else {
        L4C_WARN("release-self: registry_release_dataset failed (rc=%d)", rc);
    }
    g_self_subscribed = false;
}

// ----------------------------------------------------------------------------
// Cross-job telemetry counters.
// Atomics; readers take a snapshot via cross_job_counters_snapshot(). Bumps
// are constant-time and lock-free; no contention path in the open/read RPC
// handlers.
// ----------------------------------------------------------------------------
namespace {

std::atomic<uint64_t> g_opens_total{0};
std::atomic<uint64_t> g_opens_local_hit{0};
std::atomic<uint64_t> g_opens_redirect_to_peer{0};
std::atomic<uint64_t> g_opens_pfs_fallback{0};
std::atomic<uint64_t> g_peer_lookup_forwarded{0};
std::atomic<uint64_t> g_peer_lookup_handled{0};
std::atomic<uint64_t> g_peer_lookup_has_yes{0};
std::atomic<uint64_t> g_peer_lookup_has_no{0};
std::atomic<uint64_t> g_peer_lookup_timeout{0};

std::mutex            g_stats_log_mtx;
CrossJobCounters      g_stats_last_logged = {};
bool                  g_stats_have_baseline = false;

}  // namespace

CrossJobCounters cross_job_counters_snapshot() {
    CrossJobCounters c;
    c.opens_total            = g_opens_total.load();
    c.opens_local_hit        = g_opens_local_hit.load();
    c.opens_redirect_to_peer = g_opens_redirect_to_peer.load();
    c.opens_pfs_fallback     = g_opens_pfs_fallback.load();
    c.peer_lookup_forwarded  = g_peer_lookup_forwarded.load();
    c.peer_lookup_handled    = g_peer_lookup_handled.load();
    c.peer_lookup_has_yes    = g_peer_lookup_has_yes.load();
    c.peer_lookup_has_no     = g_peer_lookup_has_no.load();
    c.peer_lookup_timeout    = g_peer_lookup_timeout.load();
    return c;
}

void cross_job_counter_bump_opens_total()            { g_opens_total.fetch_add(1, std::memory_order_relaxed); }
void cross_job_counter_bump_opens_local_hit()        { g_opens_local_hit.fetch_add(1, std::memory_order_relaxed); }
void cross_job_counter_bump_opens_redirect_to_peer() { g_opens_redirect_to_peer.fetch_add(1, std::memory_order_relaxed); }
void cross_job_counter_bump_opens_pfs_fallback()     { g_opens_pfs_fallback.fetch_add(1, std::memory_order_relaxed); }
void cross_job_counter_bump_peer_lookup_forwarded()  { g_peer_lookup_forwarded.fetch_add(1, std::memory_order_relaxed); }
void cross_job_counter_bump_peer_lookup_handled()    { g_peer_lookup_handled.fetch_add(1, std::memory_order_relaxed); }
void cross_job_counter_bump_peer_lookup_has_yes()    { g_peer_lookup_has_yes.fetch_add(1, std::memory_order_relaxed); }
void cross_job_counter_bump_peer_lookup_has_no()     { g_peer_lookup_has_no.fetch_add(1, std::memory_order_relaxed); }
void cross_job_counter_bump_peer_lookup_timeout()    { g_peer_lookup_timeout.fetch_add(1, std::memory_order_relaxed); }

// ----------------------------------------------------------------------------
// Remote presence map (Option 2 storage layer).
// Pure C++; no Mercury dependency. The Mercury-side RPC handler that fills
// this map lives in src/comm/fitcache_comm_server.cpp.
// ----------------------------------------------------------------------------
namespace {

std::shared_mutex                            g_remote_presence_mtx;
std::unordered_map<std::string, std::string> g_remote_presence_path_to_addr;

}  // namespace

std::string remote_presence_lookup(const std::string &path) {
    std::shared_lock<std::shared_mutex> rlock(g_remote_presence_mtx);
    auto it = g_remote_presence_path_to_addr.find(path);
    return (it == g_remote_presence_path_to_addr.end()) ? std::string()
                                                        : it->second;
}

size_t remote_presence_count() {
    std::shared_lock<std::shared_mutex> rlock(g_remote_presence_mtx);
    return g_remote_presence_path_to_addr.size();
}

void remote_presence_clear_for_test() {
    std::unique_lock<std::shared_mutex> wlock(g_remote_presence_mtx);
    g_remote_presence_path_to_addr.clear();
}

void remote_presence_insert(const std::string &path,
                            const std::string &addr) {
    if (path.empty() || addr.empty()) return;
    std::unique_lock<std::shared_mutex> wlock(g_remote_presence_mtx);
    g_remote_presence_path_to_addr[path] = addr;
}

void log_cross_job_stats(int server_rank) {
    CrossJobCounters cur = cross_job_counters_snapshot();

    std::lock_guard<std::mutex> lock(g_stats_log_mtx);
    if (!g_stats_have_baseline) {
        L4C_INFO("cross_job_stats[rank=%d]: opens_total=%lu local_hit=%lu "
                 "redirect_to_peer=%lu pfs_fallback=%lu | "
                 "peer_lookup forwarded=%lu handled=%lu has_yes=%lu has_no=%lu "
                 "timeout=%lu (first sample; no delta)",
                 server_rank,
                 (unsigned long)cur.opens_total,
                 (unsigned long)cur.opens_local_hit,
                 (unsigned long)cur.opens_redirect_to_peer,
                 (unsigned long)cur.opens_pfs_fallback,
                 (unsigned long)cur.peer_lookup_forwarded,
                 (unsigned long)cur.peer_lookup_handled,
                 (unsigned long)cur.peer_lookup_has_yes,
                 (unsigned long)cur.peer_lookup_has_no,
                 (unsigned long)cur.peer_lookup_timeout);
        g_stats_last_logged = cur;
        g_stats_have_baseline = true;
        return;
    }

    const CrossJobCounters &p = g_stats_last_logged;
    L4C_INFO("cross_job_stats[rank=%d]: opens_total=%lu(+%lu) local_hit=%lu(+%lu) "
             "redirect_to_peer=%lu(+%lu) pfs_fallback=%lu(+%lu) | "
             "peer_lookup forwarded=%lu(+%lu) handled=%lu(+%lu) "
             "has_yes=%lu(+%lu) has_no=%lu(+%lu) timeout=%lu(+%lu)",
             server_rank,
             (unsigned long)cur.opens_total,            (unsigned long)(cur.opens_total            - p.opens_total),
             (unsigned long)cur.opens_local_hit,        (unsigned long)(cur.opens_local_hit        - p.opens_local_hit),
             (unsigned long)cur.opens_redirect_to_peer, (unsigned long)(cur.opens_redirect_to_peer - p.opens_redirect_to_peer),
             (unsigned long)cur.opens_pfs_fallback,     (unsigned long)(cur.opens_pfs_fallback     - p.opens_pfs_fallback),
             (unsigned long)cur.peer_lookup_forwarded,  (unsigned long)(cur.peer_lookup_forwarded  - p.peer_lookup_forwarded),
             (unsigned long)cur.peer_lookup_handled,    (unsigned long)(cur.peer_lookup_handled    - p.peer_lookup_handled),
             (unsigned long)cur.peer_lookup_has_yes,    (unsigned long)(cur.peer_lookup_has_yes    - p.peer_lookup_has_yes),
             (unsigned long)cur.peer_lookup_has_no,     (unsigned long)(cur.peer_lookup_has_no     - p.peer_lookup_has_no),
             (unsigned long)cur.peer_lookup_timeout,    (unsigned long)(cur.peer_lookup_timeout    - p.peer_lookup_timeout));
    g_stats_last_logged = cur;
}

}  // namespace fitcache
