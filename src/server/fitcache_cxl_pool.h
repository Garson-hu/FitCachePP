#pragma once
#ifndef __FitCache_CXL_POOL_H__
#define __FitCache_CXL_POOL_H__

#include <cstdint>
#include <functional>
#include <string>
#include <sys/types.h>

/*
 * CXL tier: one pre-allocated file per server process, mapped once, with
 * cached files packed into the mapping.
 *
 * The tier targets CXL memory exposed through famfs, where a cached file
 * cannot simply be copied into a directory the way the DRAM/PMem/NVMe tiers
 * do it: famfs files must be created at their final size through libfamfs
 * (about 2 s per create), cannot be renamed or deleted, and are allocated in
 * 2 MiB units. Packing everything into one backing file costs a single create
 * per server and lets the space be reused by resetting the index.
 *
 * What the pool holds is recorded in an index file on a regular filesystem so
 * a restarted server can keep serving it. Removing that index file empties
 * the pool.
 *
 * The backing file may also live on a regular filesystem (tmpfs, NVMe); that
 * path needs no libfamfs and is what the tests use.
 */
namespace fitcache {

// Set up this server's pool of `capacity` bytes under `dir`. `index_dir` must
// be on a regular filesystem. `restored` is called once for every file
// recovered from a previous server lifetime with (original_path, pool_ref).
// Returns 0 on success, -1 if the tier cannot be used.
int cxl_pool_init(const std::string &dir, uint64_t capacity, int server_rank,
                  const std::string &index_dir,
                  const std::function<void(const std::string &,
                                           const std::string &)> &restored);

// Copy `size` bytes of original_path into the pool. On success returns 0 and
// sets pool_ref, the value to store in path_cache_map (not an openable path).
// Returns -1 if the pool is full or the copy fails.
int cxl_pool_store(const std::string &original_path, uint64_t size,
                   std::string &pool_ref);

// RPC-handler side. cxl_pool_open returns a server fd for a pooled file, or -1
// if original_path is not in the pool. The other three return false when `fd`
// did not come from cxl_pool_open, so the caller falls through to the regular
// fd path. cxl_pool_close only forgets the fd; the caller still close()s it.
int  cxl_pool_open(const std::string &original_path);
bool cxl_pool_read(int fd, void *buf, size_t want, int64_t offset, ssize_t *got);
bool cxl_pool_seek(int fd, int64_t offset, int whence, int64_t *result);
void cxl_pool_close(int fd);

}  // namespace fitcache

#endif  // __FitCache_CXL_POOL_H__
