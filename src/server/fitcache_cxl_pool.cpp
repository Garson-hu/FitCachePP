/*
 * CXL tier pool — see fitcache_cxl_pool.h for the design.
 */
#include "fitcache_cxl_pool.h"
#include "fitcache_logging.h"

#ifdef FITCACHE_HAVE_FAMFS
extern "C" {
#include "famfs_lib.h"
}
#endif

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <random>
#include <sstream>
#include <unordered_map>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace fitcache {

namespace {

// Extents are page aligned so a cached file can later be mapped on its own.
const uint64_t POOL_ALIGN = 4096;
// The first page of the pool holds the header below; data starts after it.
const uint64_t POOL_DATA_START = POOL_ALIGN;
const char POOL_MAGIC[8] = {'F', 'I', 'T', 'C', 'X', 'L', 'P', '1'};

// `generation` ties an index file to the pool contents it describes. CXL
// memory is volatile: after a reboot the pool file is recreated empty and gets
// a new generation, so an index left over on disk is recognised as stale.
struct PoolHeader {
    char     magic[8];
    uint64_t generation;
};

struct Extent {
    uint64_t off;
    uint64_t size;
};

struct OpenFile {
    Extent  ext;
    int64_t pos;   // position for read() without an explicit offset
};

std::mutex g_mtx;
// Set once the pool is usable. The RPC handlers call the hooks below on every
// open/read/seek/close, so with the tier off they return before taking g_mtx.
std::atomic<bool> g_ready{false};
int        g_pool_fd = -1;
char      *g_base = nullptr;
uint64_t   g_capacity = 0;
uint64_t   g_next = POOL_DATA_START;   // bump pointer: next free byte
std::string g_pool_path;
FILE      *g_index_file = nullptr;
std::unordered_map<std::string, Extent> g_index;   // original path -> extent
std::unordered_map<int, OpenFile>       g_open;    // server fd -> open file

uint64_t align_up(uint64_t n) { return (n + POOL_ALIGN - 1) / POOL_ALIGN * POOL_ALIGN; }

std::string pool_ref(uint64_t off) { return g_pool_path + "#" + std::to_string(off); }

// True if `path` lives under a famfs mount: either the kernel filesystem
// (fstype "famfs") or the fuse flavour, which mounts with a shadow= option.
bool on_famfs(const std::string &path) {
    std::ifstream mounts("/proc/mounts");
    std::string line, best_mnt;
    bool best_is_famfs = false;
    while (std::getline(mounts, line)) {
        std::istringstream ls(line);
        std::string dev, mnt, fstype, opts;
        ls >> dev >> mnt >> fstype >> opts;
        bool under = path.compare(0, mnt.size(), mnt) == 0 &&
                     (path.size() == mnt.size() || path[mnt.size()] == '/' || mnt == "/");
        if (under && mnt.size() >= best_mnt.size()) {
            best_mnt = mnt;
            best_is_famfs = fstype == "famfs" ||
                            (fstype.compare(0, 4, "fuse") == 0 &&
                             opts.find("shadow=") != std::string::npos);
        }
    }
    return best_is_famfs;
}

int create_pool_file(const std::string &dir, const std::string &file, uint64_t capacity) {
    if (on_famfs(dir)) {
#ifdef FITCACHE_HAVE_FAMFS
        if (!fs::exists(dir) &&
            famfs_mkdir_parents(dir.c_str(), 0755, geteuid(), getegid(), 0) != 0) {
            L4C_ERR("cxl-pool: famfs_mkdir_parents(%s) failed; its parent must be a "
                    "user-owned famfs directory", dir.c_str());
            return -1;
        }
        int fd = famfs_mkfile(file.c_str(), 0644, geteuid(), getegid(),
                              (size_t)capacity, NULL, 0);
        if (fd < 0) {
            L4C_ERR("cxl-pool: famfs_mkfile(%s, %" PRIu64 " bytes) failed (rc=%d)",
                    file.c_str(), capacity, fd);
            return -1;
        }
        close(fd);
        return 0;
#else
        L4C_ERR("cxl-pool: %s is on famfs but this server was built without "
                "-DFITCACHE_FAMFS=ON", dir.c_str());
        return -1;
#endif
    }
    std::error_code ec;
    fs::create_directories(dir, ec);
    int fd = open(file.c_str(), O_CREAT | O_RDWR, 0644);
    if (fd < 0 || ftruncate(fd, (off_t)capacity) != 0) {
        L4C_ERR("cxl-pool: cannot create %s (%" PRIu64 " bytes): %s",
                file.c_str(), capacity, strerror(errno));
        if (fd >= 0) close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

// Replay the index file if it belongs to this pool generation; otherwise
// start an empty one. Leaves g_index_file open for appending.
int load_index(const std::string &index_path, uint64_t generation,
               const std::function<void(const std::string &, const std::string &)> &restored) {
    int n_restored = 0;
    bool reuse = false;
    {
        std::ifstream in(index_path);
        std::string magic;
        uint64_t gen = 0;
        std::string line;
        if (std::getline(in, line)) {
            std::istringstream hs(line);
            hs >> magic >> gen;
            reuse = (magic == std::string(POOL_MAGIC, sizeof(POOL_MAGIC)) && gen == generation);
        }
        // Record: "<offset>\t<size>\t<original path>". A record is appended
        // only after its data is in the pool, so every complete line is valid;
        // a torn last line fails the bounds check and is dropped.
        while (reuse && std::getline(in, line)) {
            uint64_t off = 0, size = 0;
            int consumed = 0;
            if (sscanf(line.c_str(), "%" SCNu64 "\t%" SCNu64 "\t%n", &off, &size, &consumed) != 2 ||
                consumed == 0 || (size_t)consumed >= line.size() ||
                off < POOL_DATA_START || off + size > g_capacity)
                continue;
            std::string original = line.substr(consumed);
            g_index[original] = Extent{off, size};
            g_next = std::max(g_next, align_up(off + size));
            restored(original, pool_ref(off));
            ++n_restored;
        }
    }
    g_index_file = fopen(index_path.c_str(), reuse ? "a" : "w");
    if (!g_index_file) {
        L4C_ERR("cxl-pool: cannot open index %s: %s", index_path.c_str(), strerror(errno));
        return -1;
    }
    if (!reuse) {
        fprintf(g_index_file, "%.8s %" PRIu64 "\n", POOL_MAGIC, generation);
        fflush(g_index_file);
    }
    return n_restored;
}

}  // namespace

int cxl_pool_init(const std::string &dir, uint64_t capacity, int server_rank,
                  const std::string &index_dir,
                  const std::function<void(const std::string &,
                                           const std::string &)> &restored) {
    std::lock_guard<std::mutex> lock(g_mtx);
    if (capacity <= POOL_DATA_START) {
        L4C_ERR("cxl-pool: capacity %" PRIu64 " is too small", capacity);
        return -1;
    }
    g_capacity = capacity;

    // famfs files cannot be resized, so the size is part of the name: a
    // different capacity gets its own backing file instead of a size mismatch.
    std::string stem = "cxl_pool.rank" + std::to_string(server_rank) + "." +
                       std::to_string(capacity);
    g_pool_path = dir + "/" + stem + ".bin";

    struct stat st;
    if (stat(g_pool_path.c_str(), &st) != 0) {
        if (create_pool_file(dir, g_pool_path, capacity) != 0) return -1;
    } else if ((uint64_t)st.st_size != capacity) {
        L4C_ERR("cxl-pool: %s is %" PRIu64 " bytes, expected %" PRIu64,
                g_pool_path.c_str(), (uint64_t)st.st_size, capacity);
        return -1;
    }

    g_pool_fd = open(g_pool_path.c_str(), O_RDWR);
    if (g_pool_fd < 0) {
        L4C_ERR("cxl-pool: open %s: %s", g_pool_path.c_str(), strerror(errno));
        return -1;
    }
    void *base = mmap(NULL, capacity, PROT_READ | PROT_WRITE, MAP_SHARED, g_pool_fd, 0);
    if (base == MAP_FAILED) {
        L4C_ERR("cxl-pool: mmap %s: %s", g_pool_path.c_str(), strerror(errno));
        close(g_pool_fd);
        g_pool_fd = -1;
        return -1;
    }
    g_base = (char *)base;

    PoolHeader *hdr = (PoolHeader *)g_base;
    if (memcmp(hdr->magic, POOL_MAGIC, sizeof(POOL_MAGIC)) != 0) {
        std::random_device rd;
        hdr->generation = ((uint64_t)rd() << 32) | rd();
        memcpy(hdr->magic, POOL_MAGIC, sizeof(POOL_MAGIC));
    }

    std::error_code ec;
    fs::create_directories(index_dir, ec);
    int n = load_index(index_dir + "/" + stem + ".index", hdr->generation, restored);
    if (n < 0) {
        munmap(g_base, capacity);
        close(g_pool_fd);
        g_base = nullptr;
        g_pool_fd = -1;
        return -1;
    }
    L4C_INFO("cxl-pool: %s ready (%" PRIu64 " bytes, %d files restored, %" PRIu64 " bytes used)",
             g_pool_path.c_str(), capacity, n, g_next);
    g_ready = true;
    return 0;
}

int cxl_pool_store(const std::string &original_path, uint64_t size, std::string &ref) {
    uint64_t off;
    {
        std::lock_guard<std::mutex> lock(g_mtx);
        if (!g_base) return -1;
        auto it = g_index.find(original_path);
        if (it != g_index.end()) {
            ref = pool_ref(it->second.off);
            return 0;
        }
        if (g_next + align_up(size) > g_capacity) return -1;   // pool full
        off = g_next;
        g_next += align_up(size);
    }

    // Read the source straight into the mapping, outside the lock: the data
    // mover is the only writer and the extent is not visible to readers yet.
    int src = open(original_path.c_str(), O_RDONLY);
    uint64_t done = 0;
    while (src >= 0 && done < size) {
        ssize_t n = pread(src, g_base + off + done, size - done, (off_t)done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (uint64_t)n;
    }
    if (src >= 0) close(src);

    std::lock_guard<std::mutex> lock(g_mtx);
    if (done != size) {
        L4C_ERR("cxl-pool: copy of %s stopped at %" PRIu64 "/%" PRIu64 " bytes: %s",
                original_path.c_str(), done, size, strerror(errno));
        if (g_next == off + align_up(size)) g_next = off;   // give the space back
        return -1;
    }
    g_index[original_path] = Extent{off, size};
    fprintf(g_index_file, "%" PRIu64 "\t%" PRIu64 "\t%s\n", off, size, original_path.c_str());
    fflush(g_index_file);
    ref = pool_ref(off);
    return 0;
}

int cxl_pool_open(const std::string &original_path) {
    if (!g_ready) return -1;
    std::lock_guard<std::mutex> lock(g_mtx);
    auto it = g_index.find(original_path);
    if (it == g_index.end()) return -1;
    // The fd only has to be a unique handle for the client's read/seek/close
    // RPCs; data is served from the mapping, never through this descriptor.
    int fd = dup(g_pool_fd);
    if (fd >= 0) g_open[fd] = OpenFile{it->second, 0};
    return fd;
}

bool cxl_pool_read(int fd, void *buf, size_t want, int64_t offset, ssize_t *got) {
    if (!g_ready) return false;
    Extent ext;
    int64_t pos;
    {
        std::lock_guard<std::mutex> lock(g_mtx);
        auto it = g_open.find(fd);
        if (it == g_open.end()) return false;
        ext = it->second.ext;
        pos = (offset != -1) ? offset : it->second.pos;
        size_t n = (pos < 0 || (uint64_t)pos >= ext.size)
                       ? 0 : (size_t)std::min<uint64_t>(want, ext.size - (uint64_t)pos);
        if (offset == -1) it->second.pos += (int64_t)n;
        *got = (ssize_t)n;
    }
    if (*got > 0) memcpy(buf, g_base + ext.off + pos, (size_t)*got);
    return true;
}

bool cxl_pool_seek(int fd, int64_t offset, int whence, int64_t *result) {
    if (!g_ready) return false;
    std::lock_guard<std::mutex> lock(g_mtx);
    auto it = g_open.find(fd);
    if (it == g_open.end()) return false;
    int64_t base = (whence == SEEK_SET) ? 0
                 : (whence == SEEK_CUR) ? it->second.pos
                 : (whence == SEEK_END) ? (int64_t)it->second.ext.size
                 : -1;
    if (base < 0 || base + offset < 0) {
        *result = -1;
        return true;
    }
    it->second.pos = base + offset;
    *result = it->second.pos;
    return true;
}

void cxl_pool_close(int fd) {
    if (!g_ready) return;
    std::lock_guard<std::mutex> lock(g_mtx);
    g_open.erase(fd);
}

}  // namespace fitcache
