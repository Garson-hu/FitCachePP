/*
 * gettid() shim for glibc < 2.30 (RHEL 8 ships glibc 2.28). The vendored
 * libfamfs (built against an older toolchain or with this same shim)
 * references gettid as an external symbol. Linking-time provide our own.
 */
#include <unistd.h>
#include <sys/syscall.h>

#ifndef SYS_gettid
#error "SYS_gettid unavailable on this system"
#endif

pid_t gettid(void) {
    return syscall(SYS_gettid);
}
