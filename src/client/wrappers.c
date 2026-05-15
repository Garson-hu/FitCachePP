/*****************************************************************************
 * Author:     Christopher J. Zimmer
 *             Oak Ridge National Lab
 * Date:       11/11/2020
 * Purpose:    Functions & structures for intercepting I/O calls for caching.
 *
 * Updated:    01/08/2021 - Purpose moved to FitCache modified to build without 
 *             warning under C++ : Skeleton for FitCache Built and configured
 * 
 * Copyright 2020 UT Battelle, LLC
 *
 * This work was supported by the Oak Ridge Leadership Computing Facility at
 * the Oak Ridge National Laboratory, which is managed by UT Battelle, LLC for
 * the U.S. DOE (under the contract No. DE-AC05-00OR22725).
 *
 * This file is part of the FitCache project.
 ****************************************************************************/

#include <dlfcn.h>
#include <string.h>
#include <assert.h>
#include <time.h>
#include "fitcache_internal.h"
#include "fitcache_logging.h"
#include "execinfo.h"

// ms_read() lives in fitcache_multi_source_read.{cpp,h}. The header is
// extern "C"-guarded so this C TU can include it directly; without it the
// compiler treats ms_read as implicitly declared and the build warns
// "implicit declaration of function 'ms_read'".
#include "fitcache_multi_source_read.h"

// Global symbol that will "turn off" all I/O redirection.  Set during init
// and shutdown to prevent us from getting into init loops that cause a
// segfault. (ie: fopen() calls fitcache_init()) which needs to write a log
// message, so it calls fopen()...)
extern bool g_disable_redirect;

// Thread-local symbol for disabling redirects.  Used by the L4C_* macros
// to make sure I/O to our log files doesn't get redirected.
extern __thread bool tl_disable_redirect;


struct Stats {
    size_t count;          // 调用次数
    double total_time;   // 总运行时间
};

struct Stats open_stats = {0, 0.0};
struct Stats open_data_stats = {0, 0.0};
struct Stats open_system_stats = {0, 0.0};
struct Stats fopen_stats = {0, 0.0};
struct Stats close_stats = {0, 0.0};
struct Stats read_stats = {0, 0.0};
struct Stats pread_stats = {0, 0.0};

bool verbose = 0;

/* fopen wrapper */
FILE *WRAP_DECL(fopen)(const char *path, const char *mode)
{
	struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
	MAP_OR_FAIL(fopen);
	if (g_disable_redirect || tl_disable_redirect) return __real_fopen( path, mode);

	FILE *ptr = __real_fopen(path,mode);

	if (ptr != NULL)
	{
		if (fitcache_track_file(path, O_RDONLY, fileno(ptr)))
		{
			L4C_INFO("FOpen: Tracking File %s",path);
		}
	}	
    clock_gettime(CLOCK_MONOTONIC, &end);
	double delta;
	if(end.tv_nsec > start.tv_nsec) {
		delta = (end.tv_sec - start.tv_sec)  + (end.tv_nsec - start.tv_nsec) / 1e9;
	}
	else{
		delta = (end.tv_sec - start.tv_sec) - 1  + ((end.tv_nsec - start.tv_nsec) + 1000000000) / 1e9;
	}
    if(verbose)
		printf("DEBUG_HU: FitCache: Fopen from pathname %s, delta: %.8f\n", path, delta);
    fflush(stdout);
	return ptr;
}


/* fopen wrapper */
FILE *WRAP_DECL(fopen64)(const char *path, const char *mode)
{

	MAP_OR_FAIL(fopen64);
	if (g_disable_redirect || tl_disable_redirect) return __real_fopen64( path, mode);

	FILE *ptr = __real_fopen64(path,mode);

	if (ptr != NULL)
	{
		if (fitcache_track_file(path, O_RDONLY, fileno(ptr)))
		{
			L4C_INFO("FOpen64: Tracking File %s",path);
		}
	}	
	
	return ptr;
}


int WRAP_DECL(open)(const char *pathname, int flags, ...)
{
	struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
	int ret = 0;
	va_list ap;
	int mode = 0;


	if (flags & O_CREAT)
	{
		va_start(ap, flags);
		mode = va_arg(ap, int);
		va_end(ap);
	}

	MAP_OR_FAIL(open);
	if (g_disable_redirect || tl_disable_redirect) return __real_open(pathname, flags, mode);

	/* For now pass the open to GPFS  - I think the open is cheap
	 * possibly asychronous.
	 * If this impedes performance we can investigate a cheap way of generating an FD
	 TODO: should we pass the open to GPFS?
	 */
	ret = __real_open(pathname, flags, mode);
	// Determines whether to track
	if (ret != -1){
		if (fitcache_track_file(pathname, flags, ret))
		{	
			L4C_INFO("Tracked Open fd %d from pathname %s: %.8f\n", ret, pathname);
		}
	}
	return ret;
}

int WRAP_DECL(open64)(const char *pathname, int flags, ...)
{
	struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
	int ret = 0;
	va_list ap;
	int mode = 0;


	if (flags & O_CREAT)
	{
		va_start(ap, flags);
		mode = va_arg(ap, int);
		va_end(ap);
	}


	MAP_OR_FAIL(open64);
	if (g_disable_redirect || tl_disable_redirect) return __real_open64(pathname, flags, mode);	


	if (mode)
	{
		ret = __real_open64(pathname, flags, mode);
	}
	else
	{
		ret = __real_open64(pathname, flags);
	}


	if (ret != -1)
	{
		if (fitcache_track_file(pathname, flags, ret))
		{
			clock_gettime(CLOCK_MONOTONIC, &end);
			double delta;
			if(end.tv_nsec > start.tv_nsec) {
				delta = (end.tv_sec - start.tv_sec)  + (end.tv_nsec - start.tv_nsec) / 1e9;
			}
			else{
				delta = (end.tv_sec - start.tv_sec) - 1  + ((end.tv_nsec - start.tv_nsec) + 1000000000) / 1e9;
			}
			if(verbose)
				printf("DEBUG_HU: FitCache: Tracked Open64 fd %d from pathname %s, delta: %.8f\n", ret, pathname, delta);
			fflush(stdout);
			L4C_INFO("Open64: Tracking file %s",pathname);
		}else{
			clock_gettime(CLOCK_MONOTONIC, &end);
			double delta;
			if(end.tv_nsec > start.tv_nsec) {
				delta = (end.tv_sec - start.tv_sec)  + (end.tv_nsec - start.tv_nsec) / 1e9;
			}
			else{
				delta = (end.tv_sec - start.tv_sec) - 1  + ((end.tv_nsec - start.tv_nsec) + 1000000000) / 1e9;
			}
			if(verbose)
				printf("DEBUG_HU: FitCache: Tracked Open64 fd %d from pathname %s, delta: %.8f\n", ret, pathname, delta);
			fflush(stdout);
		}
	}

	
	return ret;

}



int WRAP_DECL(close)(int fd)
{
	struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
	int ret = 0;

	/* Check if fitcache data has been initialized? Can we possibly hit a close call before an open call? */
	MAP_OR_FAIL(close);
	if (g_disable_redirect || tl_disable_redirect) return __real_close(fd);
	// L4C_INFO("DEBUG_HU: FitCache: Tracked Close");
	const char *path = fitcache_get_path(fd);
	if (path)
	{
		if(DEBUG_HU)
			L4C_INFO("Close to file %s",path);
		fitcache_remove_fd(fd);
	}

	// fitcache_remote_close(fd);

	/* Close the passed in file-descriptor tracked or not */
	if ((ret = __real_close(fd)) != 0)
	{
		L4C_PERROR("Error from close");
		return ret;
	}
	clock_gettime(CLOCK_MONOTONIC, &end);
	double delta;
	if(end.tv_nsec > start.tv_nsec) {
		delta = (end.tv_sec - start.tv_sec)  + (end.tv_nsec - start.tv_nsec) / 1e9;
	}
	else{
		delta = (end.tv_sec - start.tv_sec) - 1  + ((end.tv_nsec - start.tv_nsec) + 1000000000) / 1e9;
	}
	fflush(stdout);
	close_stats.count++;
    close_stats.total_time += delta;
	return ret;
}

// & timer here
ssize_t WRAP_DECL(read)(int fd, void *buf, size_t count)
{

	int ret = -1;
	
    MAP_OR_FAIL(read);	
	
    const char *path = fitcache_get_path(fd);
	// ret = fitcache_remote_read(fd,buf,count); 

	ret = ms_read(fd, buf, count, (int64_t) -1);

	if (path)
    {
        L4C_INFO("Read to file %s of size %ld returning %ld bytes",path,count,ret);
    }
	
	if (ret == -1)
	{
		ret = __real_read(fd,buf,count);	
	}
    return ret;
}

ssize_t WRAP_DECL(pread)(int fd, void *buf, size_t count, off_t offset)
{
	struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
	ssize_t ret = -1;
	MAP_OR_FAIL(pread);
	// L4C_INFO("DEBUG_HU: FitCache: Tracked PRead");

	const char *path = fitcache_get_path(fd);
	if (path)
	{             
		if(DEBUG_HU)
			L4C_INFO("pread to tracked file %s",path);
		// ret = fitcache_remote_pread(fd, buf, count, offset);
		ret = ms_read(fd,buf,count, offset);

		if (ret == -1)
		{
			ret = __real_pread(fd,buf,count,offset);
			if(DEBUG_HU)
				L4C_INFO("Pread to file %s of should be fitcache_remote_read but actually _read_read", path);
		}

		// ! Begin pread delta time
		clock_gettime(CLOCK_MONOTONIC, &end);
		double delta;
        if(end.tv_nsec > start.tv_nsec) {
            delta = (end.tv_sec - start.tv_sec)  + (end.tv_nsec - start.tv_nsec) / 1e9;
        }
        else{
            delta = (end.tv_sec - start.tv_sec) - 1  + ((end.tv_nsec - start.tv_nsec) + 1000000000) / 1e9;
        }
		if(DEBUG_HU)
			L4C_INFO("DEBUG_HU: FitCache: Tracked Pread fd %d from pathname %s, delta: %.8f\n", fd, path, delta);
		fflush(stdout);	
		pread_stats.count++;
    	pread_stats.total_time += delta;
		// ! End pread delta time

	}
	else
	{

		ret = __real_pread(fd,buf,count,offset);

		// ! Begin pread delta time
		clock_gettime(CLOCK_MONOTONIC, &end);
		double delta;
        if(end.tv_nsec > start.tv_nsec) {
            delta = (end.tv_sec - start.tv_sec)  + (end.tv_nsec - start.tv_nsec) / 1e9;
        }
        else{
            delta = (end.tv_sec - start.tv_sec) - 1  + ((end.tv_nsec - start.tv_nsec) + 1000000000) / 1e9;
        }
		if(DEBUG_HU)
			L4C_INFO("FitCache: Tracked Pread fd %d from pathname %s, delta: %.8f\n", fd, path, delta);
		fflush(stdout);	
		pread_stats.count++;
    	pread_stats.total_time += delta;
		// ! End pread delta time
	}
	
	return ret;
}



ssize_t WRAP_DECL(read64)(int fd, void *buf, size_t count)
{
	//remove me
	MAP_OR_FAIL(read64);

	const char *path = fitcache_get_path(fd);
	if (path)
	{
		L4C_INFO("Read64 to file %s of size %ld",path,count);
	}

	return __real_read64(fd,buf,count);
}

ssize_t WRAP_DECL(write)(int fd, const void *buf, size_t count)
{
	MAP_OR_FAIL(write);
	return __real_write(fd, buf, count);

	const char *path = fitcache_get_path(fd);
	if (path)
	{
		L4C_ERR("Write to file %s of size %ld",path,count);
		assert(false);
	}

	return __real_write(fd, buf, count);
}

/*
 * lseek wrapper.
 *
 * The fd we get back from the FitCache-wrapped open() IS a real PFS fd
 * (the client wrapper does __real_open before issuing the open RPC) — so
 * __real_lseek on it works directly and returns the correct file size /
 * offset. Routing the lseek through the server via fitcache_remote_lseek
 * was added for symmetry with the read path, but it has plumbing issues
 * (numpy.memmap saw SEEK_END come back as -1 → io.UnsupportedOperation)
 * and isn't actually needed: subsequent reads on tracked fds go through
 * ms_read which uses an EXPLICIT offset (pread-style), so we never depend
 * on the kernel-tracked offset of the cached-file fd on the server side.
 *
 * Keeping the wrapper around (rather than dropping it) so we can still
 * log the lseek call for traceability and so future logic that needs to
 * intercept lseek (e.g., bounded by cache-tier size) has an obvious home.
 */
off_t WRAP_DECL(lseek)(int fd, off_t offset, int whence)
{
	MAP_OR_FAIL(lseek);
	if (g_disable_redirect || tl_disable_redirect) return __real_lseek(fd,offset,whence);

	if (fitcache_file_tracked(fd) && DEBUG_HU) {
		L4C_INFO("lseek on tracked fd %d offset %ld whence %d", fd, offset, whence);
	}
	return __real_lseek(fd, offset, whence);
}

off64_t WRAP_DECL(lseek64)(int fd, off64_t offset, int whence)
{
	MAP_OR_FAIL(lseek64);
	if (g_disable_redirect || tl_disable_redirect) return __real_lseek64(fd,offset,whence);
	if (fitcache_file_tracked(fd) && DEBUG_HU) {
		L4C_INFO("lseek64 on tracked fd %d offset %ld whence %d", fd, (long)offset, whence);
	}
	return __real_lseek64(fd, offset, whence);
}

ssize_t WRAP_DECL(readv)(int fd, const struct iovec *iov, int iovcnt)
{
	MAP_OR_FAIL(readv);
	const char *path = fitcache_get_path(fd);
	if (path)
	{
		L4C_INFO("Readv to tracked file %s",path);
	}

	return __real_readv(fd, iov, iovcnt);

}
#include "fitcache_mmap_tracker.h"

/*
 * mmap wrapper — the centerpiece of the 2026-05-15 mmap-interceptor work.
 *
 * BACKGROUND: prior to this, FitCache's LD_PRELOAD client wrapped open /
 * read / pread but NOT mmap. Numpy.memmap (Megatron-LM's IndexedDataset)
 * and DINOv2's ImageNet22k tarball-slice loader both use mmap. Page faults
 * on those mappings bypass FitCache entirely, the data flows straight from
 * the PFS, and the local NVMe tier never gets exercised. The
 * workload-generalization runs on ARC measured "0 Open RPC" on those
 * workloads as a result (see benchmarks/results/arc/workload_generalization/
 * megatron_mmap_limitation.md).
 *
 * STRATEGY: for mmap on a FitCache-tracked fd, allocate an anonymous
 * mapping of the same length, eager-populate it via the existing FitCache
 * read path (ms_read → server RPC → cached-file pread → bulk transfer),
 * and return the anonymous addr. Subsequent pointer-style accesses on
 * that addr hit RAM, not the PFS. munmap reverses the transformation
 * using the (addr → length) tracker.
 *
 * TRADEOFF: eager populate means a multi-GB file pays its full read cost
 * at mmap time rather than lazily on first page fault. For training jobs
 * that touch most of the dataset every epoch this is a wash; for sparse
 * mmap users it's an overcharge. A lazier variant (mmap the cached file
 * directly via a get_cached_path RPC) is the natural follow-up.
 *
 * EXCLUSIONS: MAP_ANONYMOUS / fd<0 (no file), writable MAP_SHARED (the
 * application expects writes to flush to the backing file — our anon
 * redirect would break that contract), MAP_FIXED (must honor user addr;
 * would defeat the anonymous redirect), or any untracked fd → passthrough
 * to real mmap.
 *
 * Note on read-only MAP_SHARED: this is the path numpy.memmap mode='r'
 * actually takes (CPython mmapmodule.c maps ACCESS_READ → MAP_SHARED |
 * PROT_READ). We INTERCEPT this case — there's no write-back to honor
 * since the prot has no PROT_WRITE bit, so the anon-backing redirect is
 * semantically equivalent to a file-backed read-only shared mapping.
 */
void* WRAP_DECL(mmap)(void *addr, size_t length, int prot, int flags,
                      int fd, off_t offset)
{
    MAP_OR_FAIL(mmap);
    MAP_OR_FAIL(munmap);

    if (g_disable_redirect || tl_disable_redirect)
        return __real_mmap(addr, length, prot, flags, fd, offset);

    /* Bypass the redirect for any case we can't safely intercept.
     * MAP_SHARED is only bypassed when the mapping is WRITABLE — read-only
     * MAP_SHARED (numpy.memmap mode='r' default) is fine to redirect because
     * there's no write-back contract to honor. */
    if (fd < 0 || length == 0 ||
        (flags & MAP_ANONYMOUS) || (flags & MAP_FIXED) ||
        ((flags & MAP_SHARED) && (prot & PROT_WRITE)))
        return __real_mmap(addr, length, prot, flags, fd, offset);

    const char *path = fitcache_get_path(fd);
    if (!path)
        return __real_mmap(addr, length, prot, flags, fd, offset);

    if (DEBUG_HU)
        L4C_INFO("mmap on tracked fd %d path %s len %zu off %ld prot 0x%x flags 0x%x",
                 fd, path, length, (long)offset, prot, flags);

    /* Allocate anonymous backing memory; PROT_WRITE so we can populate it.
     * We'll mprotect down to the user-requested prot at the end. */
    void *buf = __real_mmap(NULL, length,
                            PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) {
        if (DEBUG_HU)
            L4C_INFO("mmap: anon-backing allocation failed for tracked fd %d", fd);
        return __real_mmap(addr, length, prot, flags, fd, offset);
    }

    /* Populate from the FitCache cached copy via the existing pread path.
     * ms_read returns the number of bytes actually read; anything less than
     * `length` is treated as logical EOF — the anonymous pages past that
     * point are already zero-filled, matching file-backed mmap-past-EOF
     * behaviour closely enough for the workloads we care about. */
    ssize_t got = ms_read(fd, buf, length, offset);
    if (got < 0) {
        /* Last-ditch: try a real pread on the user fd (fastest fallback
         * for the case where the FitCache server is offline). */
        got = __real_pread(fd, buf, length, offset);
    }
    if (got < 0) {
        if (DEBUG_HU)
            L4C_INFO("mmap: read into anon mapping failed for %s (got=%ld); "
                     "falling back to real mmap", path, (long)got);
        __real_munmap(buf, length);
        return __real_mmap(addr, length, prot, flags, fd, offset);
    }

    /* Apply the caller-requested protection, if it's stricter than what we
     * allocated with. mprotect is page-aligned by construction since `buf`
     * came back from mmap. */
    if (prot != (PROT_READ | PROT_WRITE)) {
        if (mprotect(buf, length, prot) != 0 && DEBUG_HU) {
            L4C_INFO("mmap: mprotect on anon mapping returned errno=%d "
                     "(continuing — read access still works)", errno);
        }
    }

    /* Track addr → length so the munmap wrapper unmaps the right region. */
    fitcache_mmap_tracker_record(buf, length);
    if (DEBUG_HU)
        L4C_INFO("mmap: redirected to anon %p (populated %ld of %zu requested bytes)",
                 buf, (long)got, length);
    return buf;
}

/*
 * mmap64 wrapper. CPython's _mmap.so calls mmap64 (the explicit 64-bit
 * variant) via glibc, NOT plain mmap — so without this wrapper the
 * numpy.memmap path skips our redirect entirely. On 64-bit Linux the
 * implementation is identical to mmap; the symbol name is what differs
 * for LD_PRELOAD interposition. Delegate to mmap so the logic lives in
 * one place.
 */
void* WRAP_DECL(mmap64)(void *addr, size_t length, int prot, int flags,
                        int fd, off64_t offset)
{
    return WRAP_DECL(mmap)(addr, length, prot, flags, fd, (off_t)offset);
}

int WRAP_DECL(munmap)(void *addr, size_t length)
{
    MAP_OR_FAIL(munmap);
    /* Look up the length we recorded at mmap time. User length may be wrong
     * (numpy.memmap sometimes rounds), but the size from the tracker is
     * authoritative for mappings we own. */
    size_t tracked_len = fitcache_mmap_tracker_lookup(addr);
    if (tracked_len > 0) {
        fitcache_mmap_tracker_drop(addr);
        return __real_munmap(addr, tracked_len);
    }
    return __real_munmap(addr, length);
}
void export_stats_to_file(const char *filename) {
	FILE *file = fopen(filename, "w");
	if (!file) {
		perror("Failed to open stats file");
		return;
	}

	fprintf(file, "Open Stats: count=%zu, total_time=%.6f\n", open_stats.count, open_stats.total_time);
	fprintf(file, "Open Data Stats: count=%zu, total_time=%.6f\n", open_data_stats.count, open_data_stats.total_time);
	fprintf(file, "Open System Stats: count=%zu, total_time=%.6f\n", open_system_stats.count, open_system_stats.total_time);
	fprintf(file, "Open total_time=%.6f\n", (open_data_stats.total_time + open_system_stats.total_time));
	fprintf(file, "Close Stats: count=%zu, total_time=%.6f\n", close_stats.count, close_stats.total_time);
	fprintf(file, "Read Stats: count=%zu, total_time=%.6f\n", read_stats.count, read_stats.total_time);
	fprintf(file, "Pread Stats: count=%zu, total_time=%.6f\n", pread_stats.count, pread_stats.total_time);

	fclose(file);
	printf("DEBUG_HU: Stats exported to %s\n", filename);
}

#if 0




size_t WRAP_DECL(fwrite)(const void *ptr, size_t size, size_t count, FILE *stream)
{
	MAP_OR_FAIL(fwrite);

	return __real_fwrite(ptr,size,count,stream);
}

int WRAP_DECL(fsync)(int fd)
{
	MAP_OR_FAIL(fsync);
	if (g_disable_redirect || tl_disable_redirect) return __real_fsync(fd);

	return __real_fsync(fd);
}

int WRAP_DECL(fdatasync)(int fd)
{
	MAP_OR_FAIL(fdatasync);
	if (g_disable_redirect || tl_disable_redirect) return __real_fdatasync(fd);

	return __real_fdatasync(fd);
}

off_t WRAP_DECL(lseek)(int fd, off_t offset, int whence)
{
	MAP_OR_FAIL(lseek);
	if (g_disable_redirect || tl_disable_redirect) return __real_lseek(fd,offset,whence);
	L4C_INFO("Got a LSEEK --- Damnit\n");
	return __real_lseek(fd, offset, whence);
}

off64_t WRAP_DECL(lseek64)(int fd, off64_t offset, int whence)
{
	MAP_OR_FAIL(lseek64);
	if (g_disable_redirect || tl_disable_redirect) return __real_lseek64(fd,offset,whence);
	if (fitcache_file_tracked(fd))
		L4C_INFO("Got an LSEEK64 on a tracked file %d %ld\n", fd, offset);
	return __real_lseek64(fd, offset, whence);
}

/* fopen wrapper */
FILE *WRAP_DECL(fopen)(const char *path, const char *mode)
{

	MAP_OR_FAIL(fopen);
	if (g_disable_redirect || tl_disable_redirect) return __real_fopen( path, mode);


	L4C_INFO("Intercepted Fopen %s",path);

	return __real_fopen(path, mode);
}



bool check_open_mode(const int flags, bool ignore_check)
{
	//Always back out of RDONLY
	if ((flags & O_ACCMODE) == O_WRONLY) {
		return false;
	}

	if ((flags & O_APPEND)) {
		return false;
	}
	return true;
}

/* Wrappers */
int WRAP_DECL(fclose)(FILE *fp)
{
	int ret = 0;

	/* RTLD Next fclose call */
	MAP_OR_FAIL(fclose);

	if (g_disable_redirect || tl_disable_redirect) return __real_fclose(fp);

	if ((ret = __real_fclose(fp)) != 0)
	{
		L4C_PERROR("Error from fclose");
		return ret;
	}

	return ret;
}


ssize_t WRAP_DECL(pwrite)(int fd, const void *buf, size_t count, off_t offset)
{
	MAP_OR_FAIL(pwrite);
	return __real_pwrite(fd, buf, count, offset);
}


ssize_t WRAP_DECL(pread)(int fd, void *buf, size_t count, off_t offset)
{
	MAP_OR_FAIL(pread);
	return __real_pread(fd,buf,count,offset);
}


ssize_t WRAP_DECL(write)(int fd, const void *buf, size_t count)
{
	MAP_OR_FAIL(write);
	return __real_write(fd, buf, count);

	const char *path = fitcache_get_path(fd);
	if (path)
	{
		L4C_INFO("Write to file %s of size %ld",path,count);
	}

	return __real_write(fd, buf, count);
}

#endif
