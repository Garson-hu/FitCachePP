/*
 * harness_read_files.c
 *
 * Tiny client binary for the multi-server localhost smoke harness in
 * scripts/run_two_server_smoke.sh. Reads every regular file in argv[1]
 * (the dataset dir) under whatever LD_PRELOAD'd FitCache client the
 * shell sets up. Reports per-file byte count and a final summary so
 * the harness can assert "N files read OK".
 *
 * Deliberately simple: no threads, no fork, no random access. The
 * goal is to exercise open/read/close on a known set of files, not to
 * benchmark anything.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define READ_BUF 4096

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <dataset-dir>\n", argv[0]);
        return 2;
    }
    const char *dir = argv[1];
    DIR *d = opendir(dir);
    if (!d) {
        fprintf(stderr, "harness: opendir(%s) failed: %s\n",
                dir, strerror(errno));
        return 1;
    }

    char path[4096];
    char buf[READ_BUF];
    int n_files = 0;
    long long n_bytes = 0;
    int n_errors = 0;

    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;          /* skip hidden + . / .. */
        snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);

        struct stat st;
        if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;

        int fd = open(path, O_RDONLY);
        if (fd < 0) {
            fprintf(stderr, "harness: open(%s) failed: %s\n",
                    path, strerror(errno));
            n_errors++;
            continue;
        }

        long long file_bytes = 0;
        ssize_t r;
        while ((r = read(fd, buf, sizeof(buf))) > 0) {
            file_bytes += r;
        }
        if (r < 0) {
            fprintf(stderr, "harness: read(%s) failed: %s\n",
                    path, strerror(errno));
            n_errors++;
        }
        close(fd);

        printf("harness: %s -> %lld bytes\n", path, file_bytes);
        n_files++;
        n_bytes += file_bytes;
    }
    closedir(d);

    printf("harness_read_files: files=%d bytes=%lld errors=%d\n",
           n_files, n_bytes, n_errors);
    return n_errors == 0 ? 0 : 1;
}
