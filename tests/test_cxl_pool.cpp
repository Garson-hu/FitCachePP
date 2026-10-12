/**
 * test_cxl_pool.cpp
 *
 * Exercises the CXL tier pool (src/server/fitcache_cxl_pool.cpp) without
 * Mercury: store, the fd-based read/seek/close surface the RPC handlers use,
 * recovery after a server restart, and reset by removing the index.
 *
 * Usage: test_cxl_pool [pool-dir]
 * The pool directory defaults to a fresh directory under /tmp. Point it at a
 * famfs directory (server built with -DFITCACHE_FAMFS=ON) to run the same
 * checks against CXL memory; the index always stays under /tmp.
 * Exits 0 on success, non-zero on the first failure.
 */

#include "fitcache_cxl_pool.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

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

static const uint64_t CAPACITY = 8ull * 1024 * 1024;
static const std::vector<uint64_t> SIZES = {1, 5000, 3ull * 1024 * 1024 + 17};

static std::string g_pool_dir, g_index_dir, g_src_dir;

static std::string src_path(size_t i) { return g_src_dir + "/sample_" + std::to_string(i); }

// Byte `off` of source file `i`; differs per file so a wrong extent shows up.
static char pattern(size_t i, uint64_t off) { return (char)((off * 31 + i * 97 + (off >> 12)) & 0xFF); }

static void write_source(size_t i, uint64_t size) {
    std::string buf(size, '\0');
    for (uint64_t o = 0; o < size; ++o) buf[o] = pattern(i, o);
    std::ofstream(src_path(i), std::ios::binary).write(buf.data(), (std::streamsize)size);
}

// Read file `i` back through the pool both ways the read RPC can ask for it.
static void check_contents(size_t i) {
    uint64_t size = SIZES[i];
    int fd = fitcache::cxl_pool_open(src_path(i));
    CHECK(fd >= 0, "pooled file did not open");

    std::vector<char> buf(size + 100);
    ssize_t got = -1;
    CHECK(fitcache::cxl_pool_read(fd, buf.data(), buf.size(), 0, &got), "pread not served by pool");
    CHECK((uint64_t)got == size, "pread past EOF must stop at the file size");
    for (uint64_t o = 0; o < size; ++o) CHECK(buf[o] == pattern(i, o), "pread returned wrong bytes");

    CHECK(fitcache::cxl_pool_read(fd, buf.data(), 10, (int64_t)size, &got) && got == 0,
          "pread at EOF must return 0");

    uint64_t seen = 0;
    char chunk[1000];
    while (fitcache::cxl_pool_read(fd, chunk, sizeof(chunk), -1, &got) && got > 0) {
        for (ssize_t k = 0; k < got; ++k)
            CHECK(chunk[k] == pattern(i, seen + (uint64_t)k), "sequential read returned wrong bytes");
        seen += (uint64_t)got;
    }
    CHECK(seen == size, "sequential read did not cover the file");

    int64_t pos = -2;
    CHECK(fitcache::cxl_pool_seek(fd, 0, SEEK_END, &pos) && (uint64_t)pos == size, "SEEK_END");
    CHECK(fitcache::cxl_pool_seek(fd, -1, SEEK_SET, &pos) && pos == -1, "negative seek must fail");
    if (size > 10) {
        CHECK(fitcache::cxl_pool_seek(fd, 10, SEEK_SET, &pos) && pos == 10, "SEEK_SET");
        CHECK(fitcache::cxl_pool_read(fd, chunk, 1, -1, &got) && got == 1 && chunk[0] == pattern(i, 10),
              "read after seek returned wrong byte");
    }

    fitcache::cxl_pool_close(fd);
    CHECK(!fitcache::cxl_pool_read(fd, chunk, 1, 0, &got), "closed fd must no longer be a pool fd");
    close(fd);
}

static int init_pool(std::vector<std::string> *restored) {
    return fitcache::cxl_pool_init(g_pool_dir, CAPACITY, 0, g_index_dir,
        [restored](const std::string &original, const std::string &) { restored->push_back(original); });
}

static void phase_fill() {
    std::vector<std::string> restored;
    CHECK(init_pool(&restored) == 0, "cxl_pool_init failed");
    CHECK(restored.empty(), "a new pool must restore nothing");

    std::string ref, ref_again;
    for (size_t i = 0; i < SIZES.size(); ++i)
        CHECK(fitcache::cxl_pool_store(src_path(i), SIZES[i], ref) == 0, "store failed");
    CHECK(fitcache::cxl_pool_store(src_path(2), SIZES[2], ref_again) == 0 && ref_again == ref,
          "storing the same file twice must return the existing extent");
    for (size_t i = 0; i < SIZES.size(); ++i) check_contents(i);

    CHECK(fitcache::cxl_pool_open(g_src_dir + "/never_stored") == -1, "unknown path must not open");
    int plain = open("/dev/null", O_RDONLY);
    ssize_t got;
    char c;
    CHECK(!fitcache::cxl_pool_read(plain, &c, 1, 0, &got), "a regular fd must not be served by the pool");
    close(plain);

    // ~3 MiB of 8 MiB is used, so a 6 MiB file cannot fit.
    std::string big = g_src_dir + "/too_big";
    std::ofstream(big, std::ios::binary).write(std::string(6 * 1024 * 1024, 'x').data(), 6 * 1024 * 1024);
    CHECK(fitcache::cxl_pool_store(big, 6 * 1024 * 1024, ref) == -1, "store into a full pool must fail");
    for (size_t i = 0; i < SIZES.size(); ++i) check_contents(i);
    std::printf("  ok: store, read, seek, close, pool-full\n");
}

static void phase_restart() {
    std::vector<std::string> restored;
    CHECK(init_pool(&restored) == 0, "cxl_pool_init after restart failed");
    CHECK(restored.size() == SIZES.size(), "restart must restore every stored file");
    for (size_t i = 0; i < SIZES.size(); ++i) check_contents(i);

    // A file stored after the restart must not overwrite the restored ones.
    std::string extra = g_src_dir + "/sample_extra", ref;
    std::ofstream(extra, std::ios::binary).write(std::string(70000, 'e').data(), 70000);
    CHECK(fitcache::cxl_pool_store(extra, 70000, ref) == 0, "store after restart failed");
    for (size_t i = 0; i < SIZES.size(); ++i) check_contents(i);
    std::printf("  ok: restart restores the index and keeps the data\n");
}

static void phase_after_index_removed() {
    std::vector<std::string> restored;
    CHECK(init_pool(&restored) == 0, "cxl_pool_init after index removal failed");
    CHECK(restored.empty(), "removing the index must empty the pool");
    CHECK(fitcache::cxl_pool_open(src_path(0)) == -1, "emptied pool must not serve old files");
    std::string ref;
    CHECK(fitcache::cxl_pool_store(src_path(1), SIZES[1], ref) == 0, "store into emptied pool failed");
    check_contents(1);
    std::printf("  ok: removing the index empties the pool and its space is reused\n");
}

// The pool is process-global state set up once per server, so each "server
// lifetime" runs in its own child process.
static void run_in_child(void (*phase)()) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        phase();
        fflush(stdout);
        _exit(0);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) std::exit(1);
}

int main(int argc, char **argv) {
    std::string scratch = "/tmp/fitcache_cxl_pool_test." + std::to_string(getpid());
    g_pool_dir  = (argc > 1) ? std::string(argv[1]) : scratch + "/pool";
    g_index_dir = scratch + "/index";
    g_src_dir   = scratch + "/src";
    fs::create_directories(g_src_dir);
    for (size_t i = 0; i < SIZES.size(); ++i) write_source(i, SIZES[i]);
    std::printf("test_cxl_pool: pool dir %s\n", g_pool_dir.c_str());

    run_in_child(phase_fill);
    run_in_child(phase_restart);
    for (const auto &e : fs::directory_iterator(g_index_dir)) fs::remove(e.path());
    run_in_child(phase_after_index_removed);

    fs::remove_all(scratch);
    std::printf("test_cxl_pool: all checks passed\n");
    return 0;
}
