/*
 * harness_read_big.c (P1-b v2) — like tests/harness_read_files.c but with a
 * 16 MiB read buffer, for the large-file traffic-accounting phase. With
 * 4 KiB reads a 1.5 GiB file costs ~400 K wrapper calls; at 16 MiB it costs
 * 96, which keeps the warm RPC pass inside the job's time budget while
 * still exercising the Mercury bulk path with large payloads.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define READ_BUF (16u * 1024u * 1024u)

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
    char *buf = malloc(READ_BUF);
    if (!buf) return 1;

    char path[4096];
    int n_files = 0, n_errors = 0;
    long long n_bytes = 0;

    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        snprintf(path, sizeof(path), "%s/%s", argv[1], e->d_name);
        struct stat st;
        if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;

        int fd = open(path, O_RDONLY);
        if (fd < 0) { n_errors++; continue; }
        ssize_t n;
        long long got = 0;
        while ((n = read(fd, buf, READ_BUF)) > 0) got += n;
        if (n < 0 || got != (long long)st.st_size) n_errors++;
        close(fd);
        n_bytes += got;
        n_files++;
        printf("bigharness: %s -> %lld bytes\n", path, got);
    }
    closedir(d);
    free(buf);
    printf("harness_read_big: files=%d bytes=%lld errors=%d\n",
           n_files, n_bytes, n_errors);
    return n_errors ? 1 : 0;
}
