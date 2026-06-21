/**
 * fitcache_persistent_meta.cpp
 *
 * See fitcache_persistent_meta.h for the public contract.
 *
 * Atomicity model:
 *   - meta_write_sidecar: write to <path>.meta.tmp.<pid>, fsync, rename
 *     to <path>.meta. Rename on POSIX is atomic; readers either see the
 *     old content or the new content, never a torn one.
 *   - meta_bump/drop_refcount: open with O_RDWR, flock LOCK_EX, read,
 *     mutate refcount, write back at offset 0, fdatasync, unlock, close.
 *     This in-place rewrite is safe because the struct is fixed-size and
 *     refcount is the only mutated field; a partial write of those four
 *     bytes is extremely unlikely on a real filesystem and would be
 *     caught by the magic check on next read anyway.
 *
 * Quarantine: if a sidecar's magic or version doesn't match what we know,
 * the scan helper renames it to <path>.broken and continues. We never
 * delete potentially-valuable data we don't understand.
 */

#include "fitcache_persistent_meta.h"

extern "C" {
#include "fitcache_logging.h"
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
}

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <string>

namespace fs = std::filesystem;

namespace fitcache {

namespace {

constexpr const char *kSidecarSuffix = ".meta";
constexpr const char *kBrokenSuffix  = ".broken";

std::string sidecar_path_for(const std::string &cached_path) {
    return cached_path + kSidecarSuffix;
}

uint64_t now_unix() {
    return static_cast<uint64_t>(std::time(nullptr));
}

bool magic_version_ok(const fitcache_file_meta_v1 &m) {
    return m.magic == FITCACHE_META_MAGIC && m.version == FITCACHE_META_VERSION;
}

}  // namespace

fitcache_file_meta_v1 meta_make_initial(const std::string &original_path,
                                        uint64_t original_size,
                                        uint64_t dataset_id_hash,
                                        uint32_t replication_mode,
                                        uint32_t replication_cap) {
    fitcache_file_meta_v1 m;
    std::memset(&m, 0, sizeof(m));
    m.magic            = FITCACHE_META_MAGIC;
    m.version          = FITCACHE_META_VERSION;
    m.dataset_id_hash  = dataset_id_hash;
    m.original_size    = original_size;
    m.cached_at_unix   = now_unix();
    m.last_access_unix = m.cached_at_unix;
    m.access_count     = 0;
    m.refcount         = 0;
    m.replication_mode = replication_mode;
    m.replication_cap  = replication_cap;
    std::strncpy(m.original_path, original_path.c_str(),
                 FITCACHE_META_PATH_MAX - 1);
    m.original_path[FITCACHE_META_PATH_MAX - 1] = '\0';
    return m;
}

int meta_write_sidecar(const std::string &cached_path,
                       const fitcache_file_meta_v1 &meta) {
    const std::string final_path = sidecar_path_for(cached_path);
    const std::string tmp_path   = final_path + ".tmp." + std::to_string(getpid());

    int fd = open(tmp_path.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) {
        L4C_ERR("meta: open %s: %s", tmp_path.c_str(), std::strerror(errno));
        return -1;
    }
    ssize_t need = sizeof(meta);
    ssize_t off  = 0;
    const char *buf = reinterpret_cast<const char *>(&meta);
    while (off < need) {
        ssize_t n = write(fd, buf + off, need - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            L4C_ERR("meta: write %s: %s", tmp_path.c_str(), std::strerror(errno));
            close(fd);
            unlink(tmp_path.c_str());
            return -1;
        }
        off += n;
    }
    if (fdatasync(fd) != 0) {
        L4C_WARN("meta: fdatasync %s: %s", tmp_path.c_str(), std::strerror(errno));
    }
    close(fd);
    if (rename(tmp_path.c_str(), final_path.c_str()) != 0) {
        L4C_ERR("meta: rename %s -> %s: %s",
                tmp_path.c_str(), final_path.c_str(), std::strerror(errno));
        unlink(tmp_path.c_str());
        return -1;
    }
    return 0;
}

int meta_read_sidecar(const std::string &cached_path,
                      fitcache_file_meta_v1 *out) {
    if (!out) return -1;
    const std::string sidecar = sidecar_path_for(cached_path);
    int fd = open(sidecar.c_str(), O_RDONLY);
    if (fd < 0) {
        return -1;          // missing is a normal "no" answer
    }
    ssize_t need = sizeof(*out);
    ssize_t off  = 0;
    char *buf = reinterpret_cast<char *>(out);
    while (off < need) {
        ssize_t n = read(fd, buf + off, need - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            L4C_ERR("meta: read %s: %s", sidecar.c_str(), std::strerror(errno));
            close(fd);
            return -1;
        }
        if (n == 0) break;  // short file
        off += n;
    }
    close(fd);
    if (off != need) {
        L4C_WARN("meta: %s short read (%zd/%zd)", sidecar.c_str(), off, need);
        return -1;
    }
    if (!magic_version_ok(*out)) {
        L4C_WARN("meta: %s bad magic/version (magic=0x%x version=%u)",
                 sidecar.c_str(), out->magic, out->version);
        return -1;
    }
    return 0;
}

namespace {

// Read-modify-write under flock for refcount mutations.
int rmw_refcount(const std::string &cached_path, int delta) {
    const std::string sidecar = sidecar_path_for(cached_path);
    int fd = open(sidecar.c_str(), O_RDWR);
    if (fd < 0) {
        L4C_ERR("meta: rmw open %s: %s", sidecar.c_str(), std::strerror(errno));
        return -1;
    }
    if (flock(fd, LOCK_EX) != 0) {
        L4C_ERR("meta: rmw flock %s: %s", sidecar.c_str(), std::strerror(errno));
        close(fd);
        return -1;
    }

    fitcache_file_meta_v1 m;
    if (pread(fd, &m, sizeof(m), 0) != static_cast<ssize_t>(sizeof(m))
        || !magic_version_ok(m)) {
        L4C_ERR("meta: rmw read/magic %s", sidecar.c_str());
        flock(fd, LOCK_UN);
        close(fd);
        return -1;
    }

    int64_t next = static_cast<int64_t>(m.refcount) + delta;
    if (next < 0) next = 0;
    m.refcount = static_cast<uint32_t>(next);
    m.last_access_unix = now_unix();
    if (delta > 0) m.access_count++;

    if (pwrite(fd, &m, sizeof(m), 0) != static_cast<ssize_t>(sizeof(m))) {
        L4C_ERR("meta: rmw write %s: %s", sidecar.c_str(), std::strerror(errno));
        flock(fd, LOCK_UN);
        close(fd);
        return -1;
    }
    fdatasync(fd);
    flock(fd, LOCK_UN);
    close(fd);
    return static_cast<int>(m.refcount);
}

}  // namespace

int meta_bump_refcount(const std::string &cached_path) {
    return rmw_refcount(cached_path, +1);
}

int meta_drop_refcount(const std::string &cached_path) {
    return rmw_refcount(cached_path, -1);
}

std::string meta_select_eviction_victim(
    const std::vector<std::string> &cached_paths) {
    std::string victim;
    uint32_t lowest_access = UINT32_MAX;
    for (const auto &cached_path : cached_paths) {
        fitcache_file_meta_v1 m;
        if (meta_read_sidecar(cached_path, &m) != 0) continue;
        if (m.refcount > 0) continue;            // protected by an active subscriber
        if (m.access_count < lowest_access) {
            lowest_access = m.access_count;
            victim = cached_path;
        }
    }
    return victim;
}

uint64_t meta_evict_file(const std::string &cached_path) {
    fitcache_file_meta_v1 m;
    if (meta_read_sidecar(cached_path, &m) != 0) {
        L4C_WARN("evict: cannot read sidecar for %s; skipping", cached_path.c_str());
        return 0;
    }
    std::error_code ec;
    fs::remove(cached_path, ec);
    if (ec) {
        L4C_ERR("evict: failed to unlink data file %s: %s",
                cached_path.c_str(), ec.message().c_str());
        return 0;
    }
    fs::remove(sidecar_path_for(cached_path), ec);   // best effort
    if (ec) {
        L4C_WARN("evict: data file gone but sidecar unlink failed for %s: %s",
                 cached_path.c_str(), ec.message().c_str());
    }
    L4C_INFO("evict: removed %s (freed %lu bytes, access_count=%u)",
             cached_path.c_str(), (unsigned long)m.original_size, m.access_count);
    return m.original_size;
}

int meta_scan_tier_dir(
    const std::string &tier_root,
    const std::function<void(const std::string &cached_path,
                             const fitcache_file_meta_v1 &meta)> &visitor) {
    std::error_code ec;
    if (!fs::exists(tier_root, ec) || !fs::is_directory(tier_root, ec)) {
        L4C_INFO("meta: tier_root %s does not exist or is not a dir; nothing to scan",
                 tier_root.c_str());
        return 0;
    }

    int valid_count = 0;
    for (auto it = fs::recursive_directory_iterator(tier_root, ec);
         it != fs::recursive_directory_iterator(); ++it) {
        if (ec) {
            L4C_WARN("meta: scan iter error: %s", ec.message().c_str());
            ec.clear();
            continue;
        }
        const fs::path &p = it->path();
        if (!p.has_extension() || p.extension().string() != kSidecarSuffix) continue;

        // Strip the .meta suffix to get the cached file path.
        std::string cached_path = p.string();
        cached_path.erase(cached_path.size() - std::strlen(kSidecarSuffix));

        // Skip if the cached file itself is gone (orphaned sidecar).
        std::error_code ec2;
        if (!fs::exists(cached_path, ec2)) {
            L4C_WARN("meta: orphaned sidecar (no data file): %s", p.string().c_str());
            continue;
        }

        fitcache_file_meta_v1 m;
        if (meta_read_sidecar(cached_path, &m) != 0) {
            // Quarantine: rename to .broken so we don't keep tripping on it.
            std::string broken = p.string() + kBrokenSuffix;
            std::error_code ec3;
            fs::rename(p, broken, ec3);
            if (ec3) {
                L4C_ERR("meta: failed to quarantine %s -> %s: %s",
                        p.string().c_str(), broken.c_str(), ec3.message().c_str());
            } else {
                L4C_WARN("meta: quarantined corrupt sidecar %s -> %s",
                         p.string().c_str(), broken.c_str());
            }
            continue;
        }
        visitor(cached_path, m);
        ++valid_count;
    }
    return valid_count;
}

}  // namespace fitcache
