/**
 * fitcache_dataset_id.cpp
 *
 * See fitcache_dataset_id.h for the public contract.
 *
 * Hash choice: FNV-1a 64-bit. Stable across processes (unlike libstdc++
 * std::hash<string>), no dependency on a third-party hash lib, fast enough
 * (~1 GB/s single-threaded) for the manifest scan since the scan is
 * disk-bound anyway.
 *
 * Design ref: tpds_extension/02_design_cross_job.md, "Dataset identity"
 * section.
 */

#include "fitcache_dataset_id.h"

extern "C" {
#include "fitcache_logging.h"
}

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

extern "C" uint64_t fitcache_fnv1a64(const void *buf, size_t len) {
    const uint64_t FNV_OFFSET = 0xcbf29ce484222325ULL;
    const uint64_t FNV_PRIME  = 0x100000001b3ULL;
    const unsigned char *p = static_cast<const unsigned char *>(buf);
    uint64_t h = FNV_OFFSET;
    for (size_t i = 0; i < len; ++i) {
        h ^= static_cast<uint64_t>(p[i]);
        h *= FNV_PRIME;
    }
    return h;
}

extern "C" uint64_t fitcache_dataset_root_path_hash(const char *canonical_root) {
    return fitcache_fnv1a64(canonical_root, std::strlen(canonical_root));
}

extern "C" int fitcache_dataset_id_eq(const fitcache_dataset_id_t *a,
                                       const fitcache_dataset_id_t *b) {
    if (!a || !b) return 0;
    if (a->root_path_hash != b->root_path_hash) return 0;
    if (a->manifest_hash  != b->manifest_hash)  return 0;
    // content_fingerprint comparison: if either side has it (non-zero),
    // both must match. Asymmetric fingerprint state means one side opted
    // out, which we conservatively treat as eligible.
    if (a->content_fingerprint != 0 && b->content_fingerprint != 0 &&
        a->content_fingerprint != b->content_fingerprint) {
        return 0;
    }
    return 1;
}

extern "C" void fitcache_dataset_id_to_hex(const fitcache_dataset_id_t *id,
                                            char *out_hex, size_t out_len) {
    if (out_len < 33) {
        if (out_len > 0) out_hex[0] = '\0';
        return;
    }
    // Fold root_path_hash and manifest_hash into 32 hex chars.
    std::snprintf(out_hex, out_len, "%016lx%016lx",
                  static_cast<unsigned long>(id->root_path_hash),
                  static_cast<unsigned long>(id->manifest_hash));
}

namespace fitcache {

namespace {

// Manifest entry format: "<size>\t<mtime>\t<path>\n"
// Hashed verbatim after sorting by path.
struct ManifestEntry {
    std::string path;
    uint64_t    size;
    int64_t     mtime;
};

bool collect_manifest(const std::string &root,
                      std::vector<ManifestEntry> &out) {
    std::error_code ec;
    auto it = fs::recursive_directory_iterator(
        root,
        fs::directory_options::skip_permission_denied,
        ec);
    if (ec) {
        L4C_ERR("dataset_id: cannot open directory %s: %s",
                root.c_str(), ec.message().c_str());
        return false;
    }
    for (const auto &entry : it) {
        if (!entry.is_regular_file(ec)) continue;
        // Skip our own sidecar files so that scanning is idempotent.
        std::string fname = entry.path().filename().string();
        if (fname == ".fitcache_dataset.v1" ||
            (fname.size() > 5 && fname.substr(fname.size() - 5) == ".meta")) {
            continue;
        }
        ManifestEntry m;
        m.path  = entry.path().lexically_relative(root).string();
        m.size  = static_cast<uint64_t>(entry.file_size(ec));
        if (ec) continue;
        auto ftime = entry.last_write_time(ec);
        if (ec) continue;
        m.mtime = ftime.time_since_epoch().count();
        out.push_back(std::move(m));
    }
    std::sort(out.begin(), out.end(),
              [](const ManifestEntry &a, const ManifestEntry &b) {
                  return a.path < b.path;
              });
    return true;
}

uint64_t hash_manifest(const std::vector<ManifestEntry> &m) {
    // Hash the canonical text encoding so that a textual cache file would
    // produce the same hash on re-load.
    const uint64_t FNV_OFFSET = 0xcbf29ce484222325ULL;
    const uint64_t FNV_PRIME  = 0x100000001b3ULL;
    uint64_t h = FNV_OFFSET;
    char buf[32];
    for (const auto &e : m) {
        int n = std::snprintf(buf, sizeof(buf), "%lu\t%ld\t",
                              static_cast<unsigned long>(e.size),
                              static_cast<long>(e.mtime));
        for (int i = 0; i < n; ++i) { h ^= static_cast<uint64_t>(buf[i]); h *= FNV_PRIME; }
        for (char c : e.path)        { h ^= static_cast<uint64_t>(c);     h *= FNV_PRIME; }
        h ^= '\n'; h *= FNV_PRIME;
    }
    return h;
}

}  // namespace

fitcache_dataset_id_t build_dataset_id(const std::string &root_path,
                                        const std::string &dataset_name,
                                        int sample_count) {
    fitcache_dataset_id_t id{};
    std::strncpy(id.name, dataset_name.c_str(), sizeof(id.name) - 1);
    id.name[sizeof(id.name) - 1] = '\0';
    id.version = 1;

    std::error_code ec;
    fs::path canonical = fs::canonical(root_path, ec);
    std::string canonical_str = ec ? root_path : canonical.string();
    id.root_path_hash = fitcache_dataset_root_path_hash(canonical_str.c_str());

    // Opt-out for large datasets where the recursive scan dominates startup.
    // When FITPP_SKIP_MANIFEST_SCAN=1, derive manifest_hash from root_path_hash
    // only. Sharing then only requires the two jobs name the *same* root path
    // — the divergence-detection refinement is sacrificed for startup speed.
    // Cosmoflow's 524288-file train/ dir takes ~37s single-threaded on Lustre;
    // with 8 ranks × parallel scans the contention cost can exceed 9 minutes.
    if (const char *skip = std::getenv("FITPP_SKIP_MANIFEST_SCAN")) {
        if (skip[0] == '1') {
            id.manifest_hash = id.root_path_hash;
            L4C_INFO("dataset_id: FITPP_SKIP_MANIFEST_SCAN=1; "
                     "manifest_hash := root_path_hash=0x%lx (no scan)",
                     (unsigned long)id.root_path_hash);
            return id;
        }
    }

    std::vector<ManifestEntry> entries;
    if (!collect_manifest(canonical_str, entries)) {
        L4C_WARN("dataset_id: manifest scan failed; manifest_hash=0");
        id.manifest_hash = 0;
        return id;
    }
    id.manifest_hash = hash_manifest(entries);

    if (sample_count > 0 && !entries.empty()) {
        // Deterministic pseudo-random sample using FNV(root || manifest)
        // mixed into a Lehmer step. Avoids std::mt19937's global-state cost
        // and gives reproducible samples across runs.
        uint64_t state = id.root_path_hash ^ id.manifest_hash ^ 0x9e3779b97f4a7c15ULL;
        const uint64_t FNV_PRIME = 0x100000001b3ULL;
        uint64_t fp = 0;
        int taken = 0;
        for (int i = 0; i < sample_count; ++i) {
            state *= FNV_PRIME;
            size_t idx = static_cast<size_t>(state % entries.size());
            std::ifstream f(canonical_str + "/" + entries[idx].path,
                            std::ios::binary);
            if (!f) continue;
            std::vector<char> buf(4096);
            f.read(buf.data(), buf.size());
            std::streamsize got = f.gcount();
            if (got > 0) {
                fp ^= fitcache_fnv1a64(buf.data(), static_cast<size_t>(got));
                ++taken;
            }
        }
        id.content_fingerprint = (taken > 0) ? fp : 0;
    }

    L4C_INFO("dataset_id: name=%s root_hash=%lx manifest_hash=%lx fp=%lx (entries=%zu)",
             id.name, id.root_path_hash, id.manifest_hash,
             id.content_fingerprint, entries.size());
    return id;
}

}  // namespace fitcache
