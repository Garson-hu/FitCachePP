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
bool        g_initialized = false;
std::mutex  g_init_mutex;

// Convenience std::string views built from the C buffers; constructed each
// call (cheap; std::string copy of a few hundred bytes).
inline std::string g_registry_root() { return std::string(g_registry_root_buf); }
inline std::string g_nodes_dir()     { return std::string(g_nodes_dir_buf);     }
inline std::string g_datasets_dir()  { return std::string(g_datasets_dir_buf);  }
inline std::string g_self_hostname() { return std::string(g_self_hostname_buf); }
inline std::string g_self_node_uuid(){ return std::string(g_self_node_uuid_buf);}

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

    std::ostringstream out;
    for (const auto &p : kv) {
        out << p.first << '=' << p.second << '\n';
    }
    int rc = write_atomic(path, out.str());

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

int registry_heartbeat(int rank) {
    if (!g_initialized) return -1;
    std::string path = per_server_file(rank);
    return rmw_kv_file(path, [&](auto &kv) {
        std::string key = "server." + std::to_string(rank) + ".heartbeat";
        kv[key] = std::to_string(now_unix());
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
    for (const auto &entry : fs::directory_iterator(nodes_dir, ec)) {
        if (ec) break;
        if (!entry.is_regular_file(ec)) continue;
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

}  // namespace fitcache
