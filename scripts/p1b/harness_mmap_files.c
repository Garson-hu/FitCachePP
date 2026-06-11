/*
 * harness_mmap_files.c  (P1-b overhead microbenchmark, 2026-06-10)
 *
 * mmap-path counterpart of tests/harness_read_files.c. For every regular
 * file in argv[1]: open -> fstat -> mmap(PROT_READ, MAP_PRIVATE) -> touch
 * one byte per 4 KiB page -> munmap -> close. Reports the mean latency of
 * the mmap() call itself (what the FitCache++ interceptor adds shows up
 * here) and the mean whole-file access time.
 *
 * Run it twice: once natively and once under LD_PRELOAD with a warm cache.
 * Under FITPP_TIMING_DUMP_ON_EXIT=1 the preloaded run additionally dumps
 * mmap.resolve_us / mmap.warmhit_total_us from the client's stat table.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static double now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec / 1e3;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <dataset-dir>\n", argv[0]);
        return 2;
    }
    DIR *d = opendir(argv[1]);
    if (!d) {
        fprintf(stderr, "opendir(%s): %s\n", argv[1], strerror(errno));
        return 1;
    }

    char path[4096];
    int n_files = 0, n_errors = 0;
    long long n_bytes = 0;
    double mmap_us_total = 0.0, file_us_total = 0.0;
    volatile unsigned char sink = 0;

    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        snprintf(path, sizeof(path), "%s/%s", argv[1], e->d_name);
        struct stat st;
        if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;

        double tf0 = now_us();
        int fd = open(path, O_RDONLY);
        if (fd < 0) { n_errors++; continue; }

        double tm0 = now_us();
        void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        double tm1 = now_us();
        if (m == MAP_FAILED) {
            n_errors++;
            close(fd);
            continue;
        }
        mmap_us_total += tm1 - tm0;

        const unsigned char *p = (const unsigned char *)m;
        for (off_t off = 0; off < st.st_size; off += 4096)
            sink ^= p[off];
        sink ^= p[st.st_size - 1];

        munmap(m, (size_t)st.st_size);
        close(fd);
        file_us_total += now_us() - tf0;
        n_files++;
        n_bytes += (long long)st.st_size;
    }
    closedir(d);

    printf("mmap-harness: files=%d errors=%d bytes=%lld "
           "mean_mmap_call_us=%.2f mean_file_us=%.2f sink=%u\n",
           n_files, n_errors, n_bytes,
           n_files ? mmap_us_total / n_files : 0.0,
           n_files ? file_us_total / n_files : 0.0,
           (unsigned)sink);
    return n_errors ? 1 : 0;
}
