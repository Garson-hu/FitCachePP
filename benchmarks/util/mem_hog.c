/*
 * mem_hog.c
 *
 * Allocate and commit a large anonymous mmap region to apply memory pressure
 * on a compute node. The kernel will evict file-backed page cache pages to
 * make room for the committed anonymous pages, simulating a dataset that
 * does not fit in RAM.
 *
 * This is for the FitCachePP overhead measurement on the rtx4060ti16g nodes,
 * where c67 / similar nodes have ~378 GB of RAM and the 8192-sample CosmoFlow
 * dataset (~50 GB) easily fits in page cache. Running this sidecar with
 * (RAM - small headroom for training) committed forces the page cache to
 * thrash, putting the workload in the I/O-bound regime where FitCache's
 * local NVMe tier can demonstrate value over BeeGFS.
 *
 * Usage:
 *   ./mem_hog <gigabytes> [<sleep_seconds_after_commit>]
 *
 * The program touches every 4 KiB page to actually commit the memory
 * (without touching, mmap is lazy and the kernel won't reserve real
 * physical pages). Then it sleeps so the calling shell can launch the
 * actual workload.
 *
 * Does NOT mlock; mlock requires CAP_IPC_LOCK or a relaxed ulimit, neither
 * of which we have on the cluster. The kernel CAN swap our anonymous pages
 * out if there's a swap device, but the rtx4060ti16g nodes have no swap
 * (verified by `swapon --show` returning empty on c67).
 *
 * Exit: SIGTERM or SIGINT cleanly munmaps and exits.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <signal.h>
#include <time.h>

static volatile int g_running = 1;
static void *g_region = NULL;
static size_t g_bytes = 0;

static void on_signal(int sig) {
    (void)sig;
    g_running = 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <gigabytes> [<sleep_seconds>]\n", argv[0]);
        return 2;
    }
    long gb = atol(argv[1]);
    if (gb <= 0) {
        fprintf(stderr, "gigabytes must be > 0\n");
        return 2;
    }
    long sleep_after = (argc >= 3) ? atol(argv[2]) : 0;

    g_bytes = (size_t)gb * 1024UL * 1024UL * 1024UL;
    fprintf(stderr, "mem_hog: requesting %ld GiB (%zu bytes)\n", gb, g_bytes);

    g_region = mmap(NULL, g_bytes, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (g_region == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    signal(SIGTERM, on_signal);
    signal(SIGINT,  on_signal);

    // Touch every page to force physical commit. Use a 4 KiB stride; this
    // matches the kernel page size on x86_64.
    const size_t PAGE = 4096;
    size_t pages = g_bytes / PAGE;
    fprintf(stderr, "mem_hog: committing %zu pages...\n", pages);
    time_t t0 = time(NULL);
    char *p = (char *)g_region;
    for (size_t i = 0; i < pages; ++i) {
        p[i * PAGE] = (char)(i & 0xff);
        // Progress every 1 GiB (262144 pages).
        if ((i & 262143UL) == 0 && i > 0) {
            time_t now = time(NULL);
            fprintf(stderr, "  committed %zu GiB, elapsed %lds\n",
                    i / 262144UL, (long)(now - t0));
        }
    }
    time_t t1 = time(NULL);
    fprintf(stderr, "mem_hog: committed %ld GiB in %lds\n", gb, (long)(t1 - t0));

    if (sleep_after > 0) {
        fprintf(stderr, "mem_hog: holding for %lds (or until signal)\n", sleep_after);
        time_t deadline = time(NULL) + sleep_after;
        while (g_running && time(NULL) < deadline) {
            sleep(1);
        }
    } else {
        fprintf(stderr, "mem_hog: holding indefinitely (signal SIGTERM to release)\n");
        while (g_running) {
            sleep(1);
        }
    }

    munmap(g_region, g_bytes);
    fprintf(stderr, "mem_hog: released\n");
    return 0;
}
