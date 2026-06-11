/*
 * harness_pread.c (P1-b v3) — pread-based sweep over every regular file in
 * argv[1] with a caller-chosen buffer size (argv[2], bytes). FitCache++
 * routes pread (not sequential read) through its ms_read RPC path, so this
 * harness exercises the same client->server->tier path as the production
 * TensorFlow/PyTorch loaders, and the ms_read.bytes_winner /
 * bytes_redundant / fetch_rpcs_issued counters fire.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <dataset-dir> <buf-bytes>\n", argv[0]);
        return 2;
    }
    size_t bufsz = (size_t)strtoull(argv[2], NULL, 10);
    if (bufsz == 0) return 2;
    char *buf = malloc(bufsz);
    if (!buf) return 1;

    DIR *d = opendir(argv[1]);
    if (!d) {
        fprintf(stderr, "opendir(%s): %s\n", argv[1], strerror(errno));
        return 1;
    }

    char path[4096];
    int n_files = 0, n_errors = 0;
    long long n_bytes = 0, n_calls = 0;

    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        snprintf(path, sizeof(path), "%s/%s", argv[1], e->d_name);
        struct stat st;
        if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;

        int fd = open(path, O_RDONLY);
        if (fd < 0) { n_errors++; continue; }
        long long got = 0;
        while (got < (long long)st.st_size) {
            ssize_t n = pread(fd, buf, bufsz, (off_t)got);
            n_calls++;
            if (n <= 0) { n_errors++; break; }
            got += n;
        }
        close(fd);
        n_bytes += got;
        n_files++;
    }
    closedir(d);
    free(buf);
    printf("harness_pread: files=%d bytes=%lld calls=%lld errors=%d bufsz=%zu\n",
           n_files, n_bytes, n_calls, n_errors, bufsz);
    return n_errors ? 1 : 0;
}
