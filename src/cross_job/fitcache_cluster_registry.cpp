/**
 * fitcache_cluster_registry.cpp
 *
 * See fitcache_cluster_registry.h for the public contract.
 *
 * On-disk format: simple key=value text, one entry per line.
 * Per-node file (`nodes/<hostname>.txt`) is a list of server records:
 *   server.0.rank=0
 *   server.0.addr=ofi+tcp;ofi_rxm://10.0.1.1:34567
 *   server.0.jobid=1234567
 *   server.0.uid=5678
 *   server.0.heartbeat=1715465700
 *   ...
 *
 * Per-dataset file (`datasets/<dsid_hex>.txt`):
 *   subscriber.<jobid>.lease_until=<unix_ts>
 *   subscriber.<jobid>.uid=<uid>
 *
 * Atomic update: write to .tmp + flock + rename. Reads tolerate concurrent
 * writes (a torn read is treated as "registry temporarily unavailable" and
 * the caller falls back to single-job behavior).
 *
 * Design ref: tpds_extension/02_design_cross_job.md, "Cluster registry"
 * section.
 */

#include "fitcache_cluster_registry.h"

extern "C" {
#include "fitcache_logging.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
}

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace fs = std::filesystem;

namespace fitcache {

namespace {

constexpr int    kHeartbeatStaleMultiplier = 3;
constexpr int    kDefaultHeartbeatSec      = 30;

// Persistent registry-dir state.
//
// EARLIER design used `std::string g_registry_root / g_nodes_dir / g_datasets_dir`
// here, set once by registry_init. Empirically those std::strings get their
// heap-backed content zeroed mid-process (same address, contents become "")
// — likely a libstdc++ destructor-ordering or heap-corruption interaction
// with the LD_PRELOAD'd shared library. Switched to fixed-size C buffers,
// never reallocated after init, to side-step the issue. The buffers are
// large enough for any reasonable PFS path.
constexpr size_t kRegPathMax = 1024;
char        g_registry_root_buf[kRegPathMax] = {0};   // .../registry.v1
char        g_nodes_dir_buf   [kRegPathMax] = {0};    // .../registry.v1/nodes
char        g_datasets_dir_buf[kRegPathMax] = {0};    // .../registry.v1/datasets
char        g_self_hostname_buf[256] = {0};
char        g_self_node_uuid_buf[256] = {0};
// Cached self-registration values populated by registry_register_server; used
// by registry_heartbeat to rewrite the full key set on every tick so the
// per-server file is self-healing if another node's gc race wipes our addr.
// See the long-form rationale comment on registry_heartbeat.
char        g_self_addr_buf [512] = {0};
char        g_self_jobid_buf[64]  = {0};
int         g_self_rank           = -1;
bool        g_initialized = false;
std::mutex  g_init_mutex;

// Convenience std::string views built from the C buffers; constructed each
// call (cheap; std::string copy of a few hundred bytes).
inline std::string g_registry_root() { return std::string(g_registry_root_buf); }
inline std::string g_nodes_dir()     { return std::string(g_nodes_dir_buf);     }
inline std::string g_datasets_dir()  { return std::string(g_datasets_dir_buf);  }
inline std::string g_self_hostname() { return std::string(g_self_hostname_buf); }
inline std::string g_self_node_uuid(){ return std::string(g_self_node_uuid_buf);}
inline std::string g_self_addr()     { return std::string(g_self_addr_buf);     }
inline std::string g_self_jobid()    { return std::string(g_self_jobid_buf);    }

int heartbeat_sec() {
    const char *v = std::getenv("FitCache_HEARTBEAT_SEC");
    if (!v) return kDefaultHeartbeatSec;
    int n = std::atoi(v);
    return (n > 0) ? n : kDefaultHeartbeatSec;
}

uint64_t now_unix() {
    return static_cast<uint64_t>(std::time(nullptr));
}

std::string read_node_uuid_or_synthesize() {
    // Prefer /etc/machine-id (stable across reboots), fall back to hostname.
    std::ifstream f("/etc/machine-id");
    std::string id;
    if (f && std::getline(f, id) && !id.empty()) return id;
    char hn[256];
    if (gethostname(hn, sizeof(hn)) == 0) {
        return std::string(hn);
    }
    return std::string("unknown-node");
}

bool ensure_dir(const std::string &p) {
    std::error_code ec;
    fs::create_directories(p, ec);
    if (ec) {
        L4C_ERR("registry: cannot create %s: %s", p.c_str(), ec.message().c_str());
        return false;
    }
    return true;
}

// Parse "key=value" lines into a map. Tolerates blank lines, comments (#), and
// short reads (returns whatever it parsed; caller decides if usable).
std::unordered_map<std::string, std::string>
parse_kv(const std::string &path) {
    std::unordered_map<std::string, std::string> kv;
    std::ifstream f(path);
    if (!f) return kv;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        kv.emplace(line.substr(0, eq), line.substr(eq + 1));
    }
    return kv;
}

// Atomic write: tmp + fsync + rename. Returns 0 on success.
int write_atomic(const std::string &final_path, const std::string &content) {
    std::string tmp = final_path + ".tmp." + std::to_string(getpid());
    {
        std::ofstream f(tmp);
        if (!f) {
            L4C_ERR("registry: cannot open %s: %s", tmp.c_str(), std::strerror(errno));
            return -1;
        }
        f << content;
        f.flush();
        if (!f) {
            L4C_ERR("registry: write failed on %s", tmp.c_str());
            std::remove(tmp.c_str());
            return -1;
        }
    }
    if (std::rename(tmp.c_str(), final_path.c_str()) != 0) {
        L4C_ERR("registry: rename %s -> %s failed: %s",
                tmp.c_str(), final_path.c_str(), std::strerror(errno));
        std::remove(tmp.c_str());
        return -1;
    }
    return 0;
}

// flock-protected read-modify-write of a single registry file.
// `update_fn` receives the current parsed kv-map and produces the new one.
//
// Implementation note: this used to go through write_atomic() (write a
// tmp file, rename onto `path`). On BeeGFS that rename() returned EBUSY
// whenever any process — including this one, since we hold fd open across
// the rename — had an open fd on `path`. The EBUSY left orphan
// `<path>.tmp.<pid>` files, which registry_gc_stale then tried to rmw
// (chained `.tmp.A.tmp.B.tmp.C` filenames and a self-perpetuating EBUSY
// storm; see registry_init's orphan sweep + iterator filters above).
//
// We now write IN PLACE under flock (ftruncate + write + fsync). The
// atomicity-via-rename property is lost, so a concurrent reader without
// flock can theoretically see a partial last line. parse_kv is line-based
// and ignores malformed lines (`if (eq == std::string::npos) continue;`),
// so a partial read costs at most one missed key-value pair, which the
// next heartbeat refreshes anyway. Worth it: zero EBUSY storms, no
// orphan tmps generated by normal operation.
template <typename UpdateFn>
int rmw_kv_file(const std::string &path, UpdateFn update_fn) {
    // Make sure the parent directory exists. registry_init creates the tree
    // at startup, but the directories can be wiped by external cleanup
    // between init and use (test scenarios, shared-PFS cleanups, etc.).
    {
        std::error_code ec;
        fs::path parent = fs::path(path).parent_path();
        if (!parent.empty() && !fs::exists(parent, ec)) {
            fs::create_directories(parent, ec);
            if (ec) {
                L4C_ERR("registry: cannot ensure parent dir %s: %s",
                        parent.c_str(), ec.message().c_str());
                return -1;
            }
        }
    }
    int fd = open(path.c_str(), O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        L4C_ERR("registry: open %s: %s", path.c_str(), std::strerror(errno));
        return -1;
    }
    if (flock(fd, LOCK_EX) != 0) {
        L4C_ERR("registry: flock %s: %s", path.c_str(), std::strerror(errno));
        close(fd);
        return -1;
    }

    auto kv = parse_kv(path);
    update_fn(kv);

    std::string content;
    {
        std::ostringstream out;
        for (const auto &p : kv) {
            out << p.first << '=' << p.second << '\n';
        }
        content = out.str();
    }

    int rc = 0;
    if (ftruncate(fd, 0) != 0) {
        L4C_ERR("registry: ftruncate %s: %s", path.c_str(), std::strerror(errno));
        rc = -1;
    } else if (lseek(fd, 0, SEEK_SET) == (off_t)-1) {
        L4C_ERR("registry: lseek %s: %s", path.c_str(), std::strerror(errno));
        rc = -1;
    } else {
        const char *buf = content.data();
        size_t remaining = content.size();
        while (remaining > 0) {
            ssize_t n = write(fd, buf, remaining);
            if (n < 0) {
                if (errno == EINTR) continue;
                L4C_ERR("registry: write %s: %s", path.c_str(), std::strerror(errno));
                rc = -1;
                break;
            }
            buf += n;
            remaining -= static_cast<size_t>(n);
        }
        if (rc == 0) (void)fsync(fd);
    }

    flock(fd, LOCK_UN);
    close(fd);
    return rc;
}

}  // namespace

int registry_init() {
    std::lock_guard<std::mutex> lock(g_init_mutex);
    if (g_initialized) return 0;

    const char *env_dir = std::getenv("FitCache_CLUSTER_REGISTRY_DIR");
    std::string root_env;
    if (env_dir && env_dir[0]) {
        root_env = env_dir;
    } else {
        const char *data_dir = std::getenv("FitCache_DATA_DIR");
        if (!data_dir || !data_dir[0]) {
            L4C_WARN("registry: neither FitCache_CLUSTER_REGISTRY_DIR nor "
                     "FitCache_DATA_DIR set; cluster registry disabled");
            return -1;
        }
        root_env = std::string(data_dir) + "/../.fitcache_registry";
    }

    std::string root_path     = root_env + "/registry.v1";
    std::string nodes_path    = root_path + "/nodes";
    std::string datasets_path = root_path + "/datasets";

    if (!ensure_dir(nodes_path) || !ensure_dir(datasets_path)) return -1;

    // Sweep orphan `<final>.tmp.<pid>` files left by previous runs whose
    // rename failed (e.g. EBUSY on BeeGFS during a prior multi-job run). If
    // we leave them, both registry_live_servers and registry_gc_stale used
    // to parse them as canonical, and gc would attempt to rmw them — which
    // generated chained `.tmp.A.tmp.B.tmp.C` names and a EBUSY storm. We
    // unlink them unconditionally at init: any process whose .tmp file
    // matters is currently holding the file open and the unlink will be a
    // no-op for the open handle's reads (Linux unlink-while-open semantics);
    // the orphan files (whose owners are dead) get cleaned. Bounded loop —
    // never glob more than a few hundred files per init.
    {
        std::error_code orphan_ec;
        int orphans_unlinked = 0;
        for (const auto &entry : fs::directory_iterator(nodes_path, orphan_ec)) {
            if (orphan_ec) break;
            if (!entry.is_regular_file(orphan_ec)) continue;
            const std::string fname = entry.path().filename().string();
            if (fname.find(".tmp.") != std::string::npos) {
                std::error_code unlink_ec;
                fs::remove(entry.path(), unlink_ec);
                if (!unlink_ec) ++orphans_unlinked;
            }
        }
        if (orphans_unlinked > 0) {
            L4C_INFO("registry_init: unlinked %d orphan .tmp.* files in %s",
                     orphans_unlinked, nodes_path.c_str());
        }
    }

    char hn[256];
    if (gethostname(hn, sizeof(hn)) != 0) {
        L4C_ERR("registry: gethostname failed");
        return -1;
    }
    std::string node_uuid = read_node_uuid_or_synthesize();

    // Copy into the C-buffer storage (no destructors run on these).
    std::strncpy(g_registry_root_buf, root_path.c_str(),     kRegPathMax - 1);
    std::strncpy(g_nodes_dir_buf,     nodes_path.c_str(),    kRegPathMax - 1);
    std::strncpy(g_datasets_dir_buf,  datasets_path.c_str(), kRegPathMax - 1);
    std::strncpy(g_self_hostname_buf, hn, sizeof(g_self_hostname_buf) - 1);
    std::strncpy(g_self_node_uuid_buf, node_uuid.c_str(), sizeof(g_self_node_uuid_buf) - 1);

    g_initialized = true;
    L4C_INFO("registry: initialized at %s (host=%s uuid=%s)",
             g_registry_root_buf, g_self_hostname_buf, g_self_node_uuid_buf);
    return 0;
}

// Per-server-instance file path: nodes/<hostname>_rank<N>.txt. Each server
// process owns its own file and is the sole writer; no inter-process write
// races. Earlier design used a single nodes/<hostname>.txt shared by all
// servers on the node, but the rmw + atomic-rename pattern broke under
// multi-server concurrency on BeeGFS — rename invalidated the inode the
// flock was bound to, so concurrent rmws lost each other's keys (only
// the heartbeat keys survived, since heartbeat update_fn was the only
// thing that ran often enough to be the last writer). Per-server files
// side-step the race entirely.
static std::string per_server_file(int rank) {
    return g_nodes_dir() + "/" + g_self_hostname()
         + "_rank" + std::to_string(rank) + ".txt";
}

int registry_register_server(const ServerEndpoint &self) {
    if (!g_initialized) return -1;
    std::string path = per_server_file(self.rank);
    std::string node_uuid = g_self_node_uuid();
    // Cache self addr/jobid/rank so registry_heartbeat can re-write the full
    // key set on every tick; see the rationale comment on registry_heartbeat.
    std::strncpy(g_self_addr_buf,  self.addr.c_str(),  sizeof(g_self_addr_buf)  - 1);
    std::strncpy(g_self_jobid_buf, self.jobid.c_str(), sizeof(g_self_jobid_buf) - 1);
    g_self_addr_buf [sizeof(g_self_addr_buf)  - 1] = '\0';
    g_self_jobid_buf[sizeof(g_self_jobid_buf) - 1] = '\0';
    g_self_rank = self.rank;
    int rc = rmw_kv_file(path, [&](auto &kv) {
        std::string p = "server." + std::to_string(self.rank) + ".";
        kv[p + "rank"]      = std::to_string(self.rank);
        kv[p + "addr"]      = self.addr;
        kv[p + "node_uuid"] = node_uuid;
        kv[p + "jobid"]     = self.jobid;
        kv[p + "uid"]       = std::to_string(getuid());
        kv[p + "heartbeat"] = std::to_string(now_unix());
    });
    if (rc == 0) {
        L4C_INFO("registry: registered server rank=%d addr=%s (file=%s)",
                 self.rank, self.addr.c_str(), path.c_str());
    }
    return rc;
}

// Heartbeat is idempotent re-registration. We rewrite addr/node_uuid/rank/
// jobid/uid alongside the refreshed heartbeat timestamp so the per-server
// file is self-healing under any wipe. This closes the cross-node gc race
// where another job's registry_gc_stale (which iterates every file in the
// shared dir) sees a transient stale heartbeat on this server's file —
// caused by occasional BeeGFS flock contention pushing one heartbeat past
// the 30s stale window — and strips server.<rank>.addr/uuid/jobid. Before
// this fix, the next heartbeat only wrote back the heartbeat key, leaving
// the file addr-less, and registry_live_servers() (which requires
// server.<rank>.addr to surface a server) silently dropped this server
// from the cluster view. Concurrent two-job runs then degenerated into
// per-node single-job clusters with 100% peer_lookup has_no.
int registry_heartbeat(int rank) {
    if (!g_initialized) return -1;
    std::string path = per_server_file(rank);
    std::string node_uuid = g_self_node_uuid();
    std::string self_addr  = g_self_addr();
    std::string self_jobid = g_self_jobid();
    return rmw_kv_file(path, [&](auto &kv) {
        std::string p = "server." + std::to_string(rank) + ".";
        kv[p + "rank"]      = std::to_string(rank);
        if (!self_addr.empty())  kv[p + "addr"]      = self_addr;
        if (!node_uuid.empty()) kv[p + "node_uuid"] = node_uuid;
        if (!self_jobid.empty()) kv[p + "jobid"]    = self_jobid;
        kv[p + "uid"]       = std::to_string(getuid());
        kv[p + "heartbeat"] = std::to_string(now_unix());
    });
}

int registry_deregister_server(int rank) {
    if (!g_initialized) return -1;
    // With per-server files, deregistration is just unlink. No rmw needed.
    std::string path = per_server_file(rank);
    std::error_code ec;
    fs::remove(path, ec);
    if (ec) {
        L4C_WARN("registry: deregister rank=%d unlink %s failed: %s",
                 rank, path.c_str(), ec.message().c_str());
        return -1;
    }
    L4C_INFO("registry: deregistered server rank=%d (removed %s)",
             rank, path.c_str());
    return 0;
}

int registry_subscribe_dataset(const fitcache_dataset_id_t &id,
                                uint32_t jobid,
                                uint64_t lease_until_unix) {
    if (!g_initialized) return -1;
    char hex[33];
    fitcache_dataset_id_to_hex(&id, hex, sizeof(hex));
    std::string path = g_datasets_dir() + "/" + hex + ".txt";
    return rmw_kv_file(path, [&](auto &kv) {
        std::string p = "subscriber." + std::to_string(jobid) + ".";
        kv[p + "lease_until"] = std::to_string(lease_until_unix);
        kv[p + "uid"]         = std::to_string(getuid());
        kv["dataset.name"]    = id.name;
        kv["dataset.manifest_hash"] = std::to_string(id.manifest_hash);
    });
}

int registry_release_dataset(const fitcache_dataset_id_t &id, uint32_t jobid) {
    if (!g_initialized) return -1;
    char hex[33];
    fitcache_dataset_id_to_hex(&id, hex, sizeof(hex));
    std::string path = g_datasets_dir() + "/" + hex + ".txt";
    std::string prefix = "subscriber." + std::to_string(jobid) + ".";
    return rmw_kv_file(path, [&](auto &kv) {
        for (auto it = kv.begin(); it != kv.end(); ) {
            if (it->first.compare(0, prefix.size(), prefix) == 0) {
                it = kv.erase(it);
            } else {
                ++it;
            }
        }
    });
}

std::vector<ServerEndpoint> registry_live_servers() {
    std::vector<ServerEndpoint> out;
    if (!g_initialized) return out;
    const std::string nodes_dir = g_nodes_dir();
    std::error_code ec;
    uint64_t now = now_unix();
    uint64_t stale = static_cast<uint64_t>(heartbeat_sec()) * kHeartbeatStaleMultiplier;

    int file_count = 0;
    for (const auto &entry : fs::directory_iterator(nodes_dir, ec)) {
        if (ec) {
            L4C_WARN("registry_live_servers: directory_iterator(%s) error: %s",
                     nodes_dir.c_str(), ec.message().c_str());
            break;
        }
        if (!entry.is_regular_file(ec)) continue;
        // Skip orphan tmp files left by failed renames — these are not
        // canonical registry files; iterating them would feed stale
        // (or zero-byte) state into the live-server snapshot.
        if (entry.path().filename().string().find(".tmp.") != std::string::npos) continue;
        ++file_count;
        auto kv = parse_kv(entry.path().string());

        // Discover the set of ranks present in this file by scanning keys
        // matching server.<r>.addr.
        for (const auto &p : kv) {
            const std::string &k = p.first;
            const std::string addr_suffix = ".addr";
            if (k.size() <= 7 || k.compare(0, 7, "server.") != 0) continue;
            if (k.size() <= addr_suffix.size() ||
                k.compare(k.size() - addr_suffix.size(),
                          addr_suffix.size(), addr_suffix) != 0) continue;

            // k = "server.<rank>.addr"
            std::string rank_str = k.substr(7, k.size() - 7 - addr_suffix.size());
            std::string base     = "server." + rank_str + ".";

            ServerEndpoint s;
            s.rank      = std::atoi(rank_str.c_str());
            s.addr      = p.second;
            auto uuid_it = kv.find(base + "node_uuid");
            s.node_uuid = (uuid_it != kv.end()) ? uuid_it->second : "";
            auto job_it = kv.find(base + "jobid");
            s.jobid     = (job_it != kv.end()) ? job_it->second : "";
            auto hb_it  = kv.find(base + "heartbeat");
            uint64_t hb = (hb_it != kv.end()) ? std::strtoull(hb_it->second.c_str(), nullptr, 10) : 0;
            s.live      = (hb > 0 && now - hb < stale);

            out.push_back(std::move(s));
        }
    }
    (void)file_count;
    return out;
}

std::vector<std::string> registry_nodes_caching_dataset(
    const fitcache_dataset_id_t &id) {
    // Today the registry tracks subscribers but not yet which nodes hold
    // cache. The sidecar-metadata work (still pending) will populate this.
    // For now return the set
    // of nodes that have *any* live server, biased by liveness — peer lookup
    // will then fan out and the per-server response says yes/no.
    (void)id;
    std::vector<std::string> out;
    if (!g_initialized) return out;
    const std::string nodes_dir = g_nodes_dir();
    std::error_code ec;
    for (const auto &entry : fs::directory_iterator(nodes_dir, ec)) {
        if (ec) break;
        if (!entry.is_regular_file(ec)) continue;
        out.push_back(entry.path().stem().string());
    }
    return out;
}

int registry_gc_stale() {
    if (!g_initialized) return -1;
    const std::string nodes_dir = g_nodes_dir();
    std::error_code ec;
    uint64_t now = now_unix();
    uint64_t stale = static_cast<uint64_t>(heartbeat_sec()) * kHeartbeatStaleMultiplier;
    int gc_count = 0;
    // Only touch files owned by THIS hostname. Each node garbage-collects its
    // own per-server files; we never modify another node's. This eliminates
    // the cross-node race where a transient stale heartbeat on a peer's file
    // (BeeGFS flock contention) lets us strip its addr key out from under it.
    const std::string self_host_prefix = g_self_hostname() + "_rank";
    for (const auto &entry : fs::directory_iterator(nodes_dir, ec)) {
        if (ec) break;
        if (!entry.is_regular_file(ec)) continue;
        // Skip orphan tmp files; rmw'ing them would generate chained
        // `<final>.tmp.<A>.tmp.<gc>` names and a rename-EBUSY storm.
        // (registry_init's orphan-tmp sweep is what removes them; gc
        // shouldn't try to interpret them as live registry state.)
        if (entry.path().filename().string().find(".tmp.") != std::string::npos) continue;
        // Hostname scope guard (see comment above on self_host_prefix).
        const std::string fname = entry.path().filename().string();
        if (fname.compare(0, self_host_prefix.size(), self_host_prefix) != 0) continue;
        std::string path = entry.path().string();

        rmw_kv_file(path, [&](auto &kv) {
            // Collect ranks whose heartbeat is stale.
            std::vector<std::string> dead;
            for (const auto &p : kv) {
                const std::string suffix = ".heartbeat";
                if (p.first.size() <= suffix.size()) continue;
                if (p.first.compare(p.first.size() - suffix.size(),
                                    suffix.size(), suffix) != 0) continue;
                uint64_t hb = std::strtoull(p.second.c_str(), nullptr, 10);
                if (hb == 0 || now - hb >= stale) {
                    // Strip trailing ".heartbeat"
                    dead.push_back(p.first.substr(0, p.first.size() - suffix.size()) + ".");
                }
            }
            for (const std::string &prefix : dead) {
                ++gc_count;
                for (auto it = kv.begin(); it != kv.end(); ) {
                    if (it->first.compare(0, prefix.size(), prefix) == 0) {
                        it = kv.erase(it);
                    } else { ++it; }
                }
            }
        });
    }
    if (gc_count > 0) {
        L4C_INFO("registry: gc removed %d stale server entries", gc_count);
    }
    return 0;
}

// ----------------------------------------------------------------------------
// Per-file presence index (Option 1).
// ----------------------------------------------------------------------------
namespace {

constexpr uint64_t kDefaultPresenceStaleSec = 180;  // 3x kDefaultHeartbeatSec

// 160-bit SHA-1 of the path, hex-encoded. We only need a stable wide hash to
// bucket presence files on PFS; cryptographic strength is not required and
// FNV-1a 64-bit would also work, but SHA-1 gives us 40 hex chars which spreads
// directory entries more uniformly across the 2x2 bucket dirs and avoids
// adversarial collisions when datasets contain many filenames with shared
// prefixes (cosmoflow's tfrecord names share a long common prefix).
//
// Implementation: minimal-deps inline SHA-1 over std::string. Output: 40-char
// lower-case hex. SHA-1 is in the C++ stdlib in C++23 but not C++20, so we
// roll our own 20-line implementation rather than pull a new dependency.
//
// NOTE: this is "use SHA-1 for hashing, not for security" — collision risk
// for a few million file paths is negligible (2^-80 birthday bound).
std::string sha1_hex(const std::string &s) {
    uint32_t h[5] = {0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u, 0xC3D2E1F0u};
    auto rotl = [](uint32_t v, int b){ return (v << b) | (v >> (32 - b)); };

    std::vector<uint8_t> buf(s.begin(), s.end());
    uint64_t bit_len = static_cast<uint64_t>(buf.size()) * 8ULL;
    buf.push_back(0x80);
    while (buf.size() % 64 != 56) buf.push_back(0x00);
    for (int i = 7; i >= 0; --i) buf.push_back((bit_len >> (i*8)) & 0xff);

    for (size_t off = 0; off + 64 <= buf.size(); off += 64) {
        uint32_t w[80];
        for (int i = 0; i < 16; ++i) {
            w[i] = (uint32_t(buf[off+4*i  ]) << 24) | (uint32_t(buf[off+4*i+1]) << 16)
                 | (uint32_t(buf[off+4*i+2]) <<  8) |  uint32_t(buf[off+4*i+3]);
        }
        for (int i = 16; i < 80; ++i) {
            w[i] = rotl(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
        for (int i = 0; i < 80; ++i) {
            uint32_t f, k;
            if      (i < 20) { f = (b & c) | ((~b) & d);            k = 0x5A827999u; }
            else if (i < 40) { f = b ^ c ^ d;                        k = 0x6ED9EBA1u; }
            else if (i < 60) { f = (b & c) | (b & d) | (c & d);      k = 0x8F1BBCDCu; }
            else             { f = b ^ c ^ d;                        k = 0xCA62C1D6u; }
            uint32_t t = rotl(a, 5) + f + e + k + w[i];
            e = d; d = c; c = rotl(b, 30); b = a; a = t;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
    }
    char out[41];
    for (int i = 0; i < 5; ++i) std::snprintf(out + i*8, 9, "%08x", h[i]);
    out[40] = 0;
    return std::string(out, 40);
}

std::string presence_dir_for_hash(const std::string &hash40) {
    return std::string(g_registry_root_buf) + "/presence/"
         + hash40.substr(0, 2) + "/" + hash40.substr(2, 2);
}

std::string presence_file_for_path(const std::string &path) {
    std::string h = sha1_hex(path);
    return presence_dir_for_hash(h) + "/" + h + ".txt";
}

bool parse_presence_line(const std::string &line, FilePresenceHolder &out) {
    // Format: "<addr>\t<unix_ts>\t<dataset_manifest_hash>"
    auto t1 = line.find('\t');
    if (t1 == std::string::npos) return false;
    auto t2 = line.find('\t', t1 + 1);
    if (t2 == std::string::npos) return false;
    out.addr           = line.substr(0, t1);
    out.last_seen_unix = std::strtoull(line.c_str() + t1 + 1, nullptr, 10);
    out.dataset_manifest_hash =
        std::strtoull(line.c_str() + t2 + 1, nullptr, 10);
    return !out.addr.empty();
}

}  // namespace

uint64_t presence_stale_sec() {
    static uint64_t cached = 0;
    static bool     cached_set = false;
    if (!cached_set) {
        const char *v = std::getenv("FitCache_PRESENCE_STALE_SEC");
        if (v) {
            int n = std::atoi(v);
            cached = (n > 0) ? static_cast<uint64_t>(n) : kDefaultPresenceStaleSec;
        } else {
            cached = kDefaultPresenceStaleSec;
        }
        cached_set = true;
    }
    return cached;
}

int registry_record_file_presence(const std::string &path,
                                  const std::string &addr,
                                  uint64_t dataset_manifest_hash) {
    if (!g_initialized) return -1;
    if (path.empty() || addr.empty()) return -1;

    const std::string file = presence_file_for_path(path);
    const std::string dir  = fs::path(file).parent_path().string();
    {
        std::error_code ec;
        fs::create_directories(dir, ec);
        if (ec) {
            L4C_WARN("presence: cannot ensure %s: %s",
                     dir.c_str(), ec.message().c_str());
            return -1;
        }
    }

    char line[1024];
    int n = std::snprintf(line, sizeof(line), "%s\t%lu\t%lu\n",
                          addr.c_str(),
                          (unsigned long)now_unix(),
                          (unsigned long)dataset_manifest_hash);
    if (n <= 0 || n >= static_cast<int>(sizeof(line))) {
        L4C_WARN("presence: line too long for %s (n=%d)", path.c_str(), n);
        return -1;
    }

    // O_APPEND + single write() < PIPE_BUF is atomic on POSIX. No flock
    // needed because each (addr) is written by only one server process; if
    // the same server records the same path twice, both lines persist and
    // the reader keeps only the latest (highest ts) per addr.
    int fd = open(file.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        L4C_WARN("presence: open %s: %s", file.c_str(), std::strerror(errno));
        return -1;
    }
    ssize_t w = ::write(fd, line, static_cast<size_t>(n));
    int saved_errno = errno;
    close(fd);
    if (w != n) {
        L4C_WARN("presence: short write to %s (wrote %zd of %d, errno=%d)",
                 file.c_str(), w, n, saved_errno);
        return -1;
    }
    return 0;
}

std::vector<FilePresenceHolder> registry_lookup_file_presence(
        const std::string &path, uint64_t max_age_sec) {
    std::vector<FilePresenceHolder> out;
    if (!g_initialized || path.empty()) return out;

    const std::string file = presence_file_for_path(path);
    std::ifstream f(file);
    if (!f) return out;   // not registered

    const uint64_t now = now_unix();
    const uint64_t age = (max_age_sec == 0) ? presence_stale_sec() : max_age_sec;

    // Dedupe by addr; keep latest ts per addr.
    std::unordered_map<std::string, FilePresenceHolder> latest_per_addr;
    std::string line;
    while (std::getline(f, line)) {
        FilePresenceHolder h;
        if (!parse_presence_line(line, h)) continue;
        if (h.last_seen_unix == 0) continue;
        if (now > h.last_seen_unix && (now - h.last_seen_unix) > age) continue;
        auto it = latest_per_addr.find(h.addr);
        if (it == latest_per_addr.end() || h.last_seen_unix > it->second.last_seen_unix) {
            latest_per_addr[h.addr] = h;
        }
    }
    out.reserve(latest_per_addr.size());
    for (auto &kv : latest_per_addr) out.push_back(kv.second);
    return out;
}

int registry_gc_file_presence(int max_files) {
    if (!g_initialized) return -1;
    const std::string root = std::string(g_registry_root_buf) + "/presence";
    std::error_code ec;
    if (!fs::exists(root, ec)) return 0;

    int scanned = 0, rewritten = 0;
    const uint64_t now  = now_unix();
    const uint64_t age  = presence_stale_sec();

    // Two-level bucket dirs.
    for (const auto &lvl1 : fs::directory_iterator(root, ec)) {
        if (ec) break;
        if (!lvl1.is_directory(ec)) continue;
        for (const auto &lvl2 : fs::directory_iterator(lvl1.path(), ec)) {
            if (ec) break;
            if (!lvl2.is_directory(ec)) continue;
            for (const auto &entry : fs::directory_iterator(lvl2.path(), ec)) {
                if (ec) break;
                if (!entry.is_regular_file(ec)) continue;
                if (scanned >= max_files) return rewritten;
                ++scanned;
                std::ifstream f(entry.path());
                if (!f) continue;
                std::vector<std::string> fresh;
                std::unordered_map<std::string, std::pair<uint64_t, std::string>>
                    latest;  // addr -> (ts, raw_line)
                std::string line;
                while (std::getline(f, line)) {
                    FilePresenceHolder h;
                    if (!parse_presence_line(line, h)) continue;
                    if (now > h.last_seen_unix && (now - h.last_seen_unix) > age) continue;
                    auto it = latest.find(h.addr);
                    if (it == latest.end() || h.last_seen_unix > it->second.first) {
                        latest[h.addr] = {h.last_seen_unix, line};
                    }
                }
                f.close();

                // Rewrite only if the deduped + filtered set is strictly
                // smaller than the on-disk file's line count (otherwise no
                // point in churning the inode).
                bool need_rewrite = false;
                {
                    std::ifstream f2(entry.path());
                    int line_count = 0;
                    std::string ln;
                    while (std::getline(f2, ln)) ++line_count;
                    if (line_count > static_cast<int>(latest.size())) need_rewrite = true;
                }
                if (!need_rewrite) continue;

                const std::string tmp = entry.path().string() + ".gc.tmp."
                                      + std::to_string(getpid());
                std::ofstream out(tmp);
                if (!out) continue;
                for (auto &kv : latest) out << kv.second.second << "\n";
                out.flush();
                if (!out) {
                    std::remove(tmp.c_str());
                    continue;
                }
                out.close();
                if (std::rename(tmp.c_str(), entry.path().c_str()) == 0) {
                    ++rewritten;
                } else {
                    std::remove(tmp.c_str());
                }
            }
        }
    }
    if (rewritten > 0) {
        L4C_INFO("presence: gc rewrote %d files (scanned=%d)", rewritten, scanned);
    }
    return rewritten;
}

}  // namespace fitcache
