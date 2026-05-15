/**
 * fitcache_mmap_tracker.cpp — see fitcache_mmap_tracker.h for the contract.
 */

#include "fitcache_mmap_tracker.h"

#include <mutex>
#include <unordered_map>

namespace {

// Per-process map of addresses we returned from the mmap wrapper to the
// length we allocated. Guarded by a single mutex; mmap is not on a hot
// path (each call corresponds to a whole file open in a training job)
// so the contention is negligible.
std::mutex                          g_mtx;
std::unordered_map<void*, size_t>   g_addr_to_length;

}  // namespace

extern "C" void fitcache_mmap_tracker_record(void *addr, size_t length) {
    if (!addr) return;
    std::lock_guard<std::mutex> lk(g_mtx);
    g_addr_to_length[addr] = length;
}

extern "C" size_t fitcache_mmap_tracker_lookup(void *addr) {
    if (!addr) return 0;
    std::lock_guard<std::mutex> lk(g_mtx);
    auto it = g_addr_to_length.find(addr);
    return (it == g_addr_to_length.end()) ? 0 : it->second;
}

extern "C" void fitcache_mmap_tracker_drop(void *addr) {
    if (!addr) return;
    std::lock_guard<std::mutex> lk(g_mtx);
    g_addr_to_length.erase(addr);
}
