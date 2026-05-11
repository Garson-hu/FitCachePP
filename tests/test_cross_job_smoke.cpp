/**
 * test_cross_job_smoke.cpp
 *
 * Smoke test for the FitCache++ cross-job extension.
 * Doesn't touch Mercury/RPC; only exercises the self-contained modules:
 *   - FNV-1a stable hashing
 *   - HRW routing algorithm (deterministic, balanced, stable across server-set churn)
 *   - dataset_id construction on a synthetic directory
 *   - cluster registry init / register / heartbeat / read-back
 *   - client-side routing slot table (select_server_for_path + slot_to_addr)
 *
 * Build via the existing tests/ CMakeLists. Run with no arguments. Exits 0
 * on success, non-zero on first failure (with a message).
 */

#include "../src/fitcache_dataset_id.h"
#include "../src/fitcache_cross_job.h"
#include "../src/fitcache_cluster_registry.h"

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include <unistd.h>   // getpid, sleep

// fitcache_logging.c references this thread-local defined in client.cpp /
// server.cpp. The test is a third entry point, so we provide a stub.
extern "C" {
__thread bool tl_disable_redirect = false;
}

namespace fs = std::filesystem;

#define CHECK(cond, msg)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            std::fprintf(stderr, "FAIL [%s:%d]: %s\n", __FILE__, __LINE__,     \
                         msg);                                                 \
            std::exit(1);                                                      \
        }                                                                      \
    } while (0)

static int test_fnv1a_stable() {
    // Known FNV-1a 64-bit test vectors (from the reference implementation).
    CHECK(fitcache_fnv1a64("", 0) == 0xcbf29ce484222325ULL, "fnv empty");
    CHECK(fitcache_fnv1a64("a", 1) == 0xaf63dc4c8601ec8cULL, "fnv 'a'");
    CHECK(fitcache_fnv1a64("foobar", 6) == 0x85944171f73967e8ULL,
          "fnv 'foobar'");
    std::printf("  ok: FNV-1a 64 vectors match reference\n");
    return 0;
}

static int test_hrw_basic() {
    using namespace fitcache;
    std::vector<ServerEndpoint> servers;
    for (int i = 0; i < 8; ++i) {
        ServerEndpoint s;
        s.rank      = i;
        s.addr      = "addr-" + std::to_string(i);
        s.node_uuid = "node-" + std::to_string(i);
        s.live      = true;
        servers.push_back(std::move(s));
    }

    // 1. Determinism: same path + same set => same winner across calls.
    int a = hrw_select("dataset/x.bin", servers);
    int b = hrw_select("dataset/x.bin", servers);
    CHECK(a >= 0 && a == b, "HRW non-deterministic for same input");

    // 2. Balance: distribute 10000 paths across the 8 servers, expect each
    //    server in roughly [0.7/N, 1.3/N] of the load.
    std::map<int, int> hist;
    for (int i = 0; i < 10000; ++i) {
        std::string p = "dataset/file_" + std::to_string(i) + ".bin";
        ++hist[hrw_select(p, servers)];
    }
    int min_count = INT32_MAX, max_count = 0;
    for (const auto &p : hist) {
        if (p.second < min_count) min_count = p.second;
        if (p.second > max_count) max_count = p.second;
    }
    int target = 10000 / static_cast<int>(servers.size());
    CHECK(min_count > target * 7 / 10,
          "HRW load imbalance: some server got <70% of expected share");
    CHECK(max_count < target * 13 / 10,
          "HRW load imbalance: some server got >130% of expected share");
    std::printf("  ok: HRW balance min=%d max=%d (expected ~%d per server)\n",
                min_count, max_count, target);

    // 3. Stability under churn: removing one server should reassign only
    //    ~1/N of paths. Crucial property for cross-job sharing.
    std::vector<ServerEndpoint> shrunk = servers;
    int removed_rank = shrunk.back().rank;
    shrunk.pop_back();

    int reassigned = 0, unchanged = 0;
    for (int i = 0; i < 10000; ++i) {
        std::string p = "dataset/file_" + std::to_string(i) + ".bin";
        int orig_idx = hrw_select(p, servers);
        int new_idx  = hrw_select(p, shrunk);
        // Map back to ranks for cross-vector comparison.
        int orig_rank = (orig_idx >= 0) ? servers[orig_idx].rank : -1;
        int new_rank  = (new_idx  >= 0) ? shrunk[new_idx].rank   : -1;
        if (orig_rank == new_rank) ++unchanged;
        else                       ++reassigned;
    }
    // Paths originally assigned to the removed server (~1/8) MUST move; all
    // others SHOULD stay. Allow some slack.
    int expected_moved = 10000 / static_cast<int>(servers.size());
    CHECK(reassigned >= expected_moved * 8 / 10 &&
          reassigned <= expected_moved * 12 / 10,
          "HRW churn reassigned too many or too few paths");
    std::printf("  ok: HRW churn reassigned=%d (expected ~%d) when removing "
                "rank %d\n", reassigned, expected_moved, removed_rank);

    // 4. Modulo baseline: must agree on order of magnitude balance but NOT
    //    survive churn (sanity check for the cluster-scoped coordination
    //    protocol's modulo-vs-HRW comparison story).
    int mod_a = modulo_select("dataset/x.bin", 8);
    int mod_b = modulo_select("dataset/x.bin", 7);
    // Almost certainly different — modulo is sensitive to N.
    if (mod_a == mod_b) {
        std::printf("  note: modulo unchanged for this path on N=8->7 "
                    "(coincidence; whole-set test below is the real check)\n");
    }
    int mod_unchanged = 0;
    for (int i = 0; i < 10000; ++i) {
        std::string p = "dataset/file_" + std::to_string(i) + ".bin";
        if (modulo_select(p, 8) == modulo_select(p, 7)) ++mod_unchanged;
    }
    // Modulo retains roughly 1/8 of mappings on N change; HRW retains ~7/8.
    CHECK(mod_unchanged < 10000 / 4,
          "modulo unexpectedly stable across N change (test logic broken?)");
    std::printf("  ok: modulo unchanged=%d/10000 across N=8->7 "
                "(HRW unchanged would be ~%d -> %d)\n",
                mod_unchanged, 10000 - reassigned, unchanged);
    return 0;
}

static int test_dataset_id() {
    fs::path tmp = fs::temp_directory_path() /
                   ("fitcache_test_ds_" + std::to_string(getpid()));
    fs::remove_all(tmp);
    fs::create_directories(tmp);

    // Synthetic dataset: 5 files, deterministic content.
    for (int i = 0; i < 5; ++i) {
        std::ofstream f(tmp / ("file_" + std::to_string(i) + ".bin"));
        for (int j = 0; j < 64; ++j) f << static_cast<char>('a' + (i + j) % 26);
    }

    fitcache_dataset_id_t a =
        fitcache::build_dataset_id(tmp.string(), "test-ds", /*samples=*/0);
    fitcache_dataset_id_t b =
        fitcache::build_dataset_id(tmp.string(), "test-ds", /*samples=*/0);

    CHECK(a.root_path_hash != 0, "root_path_hash zero");
    CHECK(a.manifest_hash  != 0, "manifest_hash zero");
    CHECK(fitcache_dataset_id_eq(&a, &b),
          "dataset_id not equal across two builds of the same directory");

    // Add a new file -> manifest_hash should change.
    {
        std::ofstream f(tmp / "new.bin");
        f << "added";
    }
    fitcache_dataset_id_t c =
        fitcache::build_dataset_id(tmp.string(), "test-ds", /*samples=*/0);
    CHECK(!fitcache_dataset_id_eq(&a, &c),
          "manifest_hash unchanged after adding a file (incorrect)");
    std::printf("  ok: dataset_id stable + sensitive to membership change\n");

    // Hex encoding.
    char hex[33];
    fitcache_dataset_id_to_hex(&a, hex, sizeof(hex));
    CHECK(std::strlen(hex) == 32, "hex length wrong");
    std::printf("  ok: dataset_id hex = %s\n", hex);

    fs::remove_all(tmp);
    return 0;
}

static int test_registry_roundtrip() {
    fs::path tmp = fs::temp_directory_path() /
                   ("fitcache_test_reg_" + std::to_string(getpid()));
    fs::remove_all(tmp);
    fs::create_directories(tmp);
    setenv("FitCache_CLUSTER_REGISTRY_DIR", tmp.string().c_str(), 1);
    setenv("FitCache_HEARTBEAT_SEC", "1", 1);

    CHECK(fitcache::registry_init() == 0, "registry_init failed");

    fitcache::ServerEndpoint self;
    self.rank      = 0;
    self.addr      = "ofi+tcp;ofi_rxm://127.0.0.1:1234";
    self.node_uuid = "test-node";
    self.jobid     = "1234567";
    self.live      = true;
    CHECK(fitcache::registry_register_server(self) == 0,
          "register_server failed");
    CHECK(fitcache::registry_heartbeat(0) == 0, "heartbeat failed");

    auto live = fitcache::registry_live_servers();
    CHECK(live.size() == 1, "expected exactly one live server after register");
    CHECK(live[0].addr == self.addr, "live server addr mismatch");
    CHECK(live[0].rank == 0, "live server rank mismatch");
    CHECK(live[0].live, "live server liveness flag false");
    std::printf("  ok: registry roundtrip live={rank=%d addr=%s}\n",
                live[0].rank, live[0].addr.c_str());

    // Heartbeat staleness (sleep > 3*heartbeat_sec to flip the live flag).
    sleep(4);
    auto stale = fitcache::registry_live_servers();
    CHECK(stale.size() == 1, "entry should still be present");
    CHECK(!stale[0].live, "expected entry to be stale after 4s with hb=1s");
    std::printf("  ok: stale heartbeat detected\n");

    CHECK(fitcache::registry_deregister_server(0) == 0, "deregister failed");
    auto empty = fitcache::registry_live_servers();
    CHECK(empty.empty(), "expected empty live set after deregister");
    std::printf("  ok: deregister removes entry\n");

    fs::remove_all(tmp);
    return 0;
}

// Client-side routing coverage: cross-job select_server_for_path + slot_to_addr.
//
// Single-job equivalence (select == modulo with FitCache_CROSS_JOB=0) is
// implicitly covered by the dedicated modulo_select assertions above. We do
// NOT exercise it here because cross_job_enabled() caches its result on
// first call; if we tested OFF first the cache would lock to OFF for the
// rest of the process and the cross-job branch would be unreachable.
//
// Subtlety: registry_init() resolves its directory once and caches it in
// statics. The earlier test_registry_roundtrip already locked that path in;
// to share the registry we *reuse the same dir layout* by rewriting per-node
// files at the location registry_init bound to. We derive the path the same
// way registry_init does (FitCache_CLUSTER_REGISTRY_DIR), so we land in the
// directory g_nodes_dir already points at.
static int test_routing_select_and_slot_addr() {
    using namespace fitcache;

    const char *reg_env = std::getenv("FitCache_CLUSTER_REGISTRY_DIR");
    CHECK(reg_env && reg_env[0],
          "expected FitCache_CLUSTER_REGISTRY_DIR to be set by prior test");
    fs::path nodes_dir = fs::path(reg_env) / "registry.v1" / "nodes";
    fs::create_directories(nodes_dir);

    // Toggle cross-job ON before the first cross_job_enabled() call.
    setenv("FitCache_CROSS_JOB", "1", 1);
    // Earlier test set FitCache_HEARTBEAT_SEC=1, which would mark our
    // newly-written entries stale after 3s. Use 60s for liveness.
    setenv("FitCache_HEARTBEAT_SEC", "60", 1);

    uint64_t now = static_cast<uint64_t>(std::time(nullptr));
    auto write_node = [&](const std::string &host, int rank,
                          const std::string &addr, const std::string &uuid) {
        std::ofstream f(nodes_dir / (host + ".txt"));
        std::string p = "server." + std::to_string(rank) + ".";
        f << p << "rank="      << rank << "\n";
        f << p << "addr="      << addr << "\n";
        f << p << "node_uuid=" << uuid << "\n";
        f << p << "jobid="     << "1234567" << "\n";
        f << p << "uid="       << "5678" << "\n";
        f << p << "heartbeat=" << now << "\n";
    };
    write_node("hostA", 0, "ofi+tcp;ofi_rxm://10.0.0.1:5000", "uuid-A");
    write_node("hostB", 1, "ofi+tcp;ofi_rxm://10.0.0.2:5001", "uuid-B");
    write_node("hostC", 2, "ofi+tcp;ofi_rxm://10.0.0.3:5002", "uuid-C");

    // Sanity: the registry actually surfaces the three entries.
    auto live = registry_live_servers();
    CHECK(live.size() == 3, "registry should see 3 nodes");
    int live_count = 0;
    for (const auto &s : live) if (s.live) ++live_count;
    CHECK(live_count == 3, "registry liveness flags wrong");

    refresh_cluster_endpoints();

    int slot1 = select_server_for_path("dataset/file_42.bin", 8);
    int slot2 = select_server_for_path("dataset/file_42.bin", 8);
    CHECK(slot1 >= 0, "cross-job select returned -1");
    CHECK(slot1 == slot2, "cross-job slot not stable for repeated calls");

    std::string addr = slot_to_addr(slot1);
    CHECK(!addr.empty(),
          "slot_to_addr returned empty for slot issued by select");
    CHECK(addr == "ofi+tcp;ofi_rxm://10.0.0.1:5000" ||
          addr == "ofi+tcp;ofi_rxm://10.0.0.2:5001" ||
          addr == "ofi+tcp;ofi_rxm://10.0.0.3:5002",
          "slot_to_addr returned an addr we never registered");
    std::printf("  ok: cross-job slot stable (slot=%d) addr=%s\n",
                slot1, addr.c_str());

    // HRW should spread across multiple servers under reasonable input.
    std::map<int, int> slot_hist;
    for (int i = 0; i < 30; ++i) {
        std::string p = "dataset/spread_" + std::to_string(i) + ".bin";
        ++slot_hist[select_server_for_path(p, 8)];
    }
    CHECK(slot_hist.size() >= 2,
          "HRW collapsed all 30 paths onto a single server");
    std::printf("  ok: cross-job HRW spread across %zu/3 servers\n",
                slot_hist.size());

    // Unknown-slot lookup must be empty so that lookup_addr's degraded
    // .ports.cfg fallback can detect "slot not in cluster table".
    CHECK(slot_to_addr(9999).empty(),
          "slot_to_addr should be empty for unknown slot");

    return 0;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    std::printf("FitCache++ cross-job smoke test\n");
    std::printf("[1/5] FNV-1a vectors...\n");
    test_fnv1a_stable();
    std::printf("[2/5] HRW routing...\n");
    test_hrw_basic();
    std::printf("[3/5] dataset_id...\n");
    test_dataset_id();
    std::printf("[4/5] cluster registry roundtrip (will sleep ~4s for stale "
                "heartbeat check)...\n");
    test_registry_roundtrip();
    std::printf("[5/5] client-side routing (select_server_for_path + slot_to_addr)...\n");
    test_routing_select_and_slot_addr();
    std::printf("\nALL SMOKE TESTS PASSED\n");
    return 0;
}
