#!/usr/bin/env python3
"""
memmap_only_iter.py

The minimal mmap-on-tracked-file probe. Equivalent to what
megatron_io_only_iter.py does for IndexedDataset, but without depending
on Megatron's .idx file format. Just opens a .bin via numpy.memmap and
iterates over slices — that's enough to exercise the libfitcache_client
mmap interceptor (commit 85c9527).

Usage:
    LD_PRELOAD=libfitcache_client.so python memmap_only_iter.py \\
        --bin /path/to/some.bin \\
        --dtype uint16 \\
        --num-iters 200 \\
        --slice-len 1024

Expected when the interceptor is wired correctly:
  - libfitcache log line: "mmap on tracked fd <N> path .../some.bin ..."
  - libfitcache log line: "mmap: redirected to anon ..."
  - server log line:      "Open RPC: requested path .../some.bin"
"""

import argparse
import os
import random
import sys
import time

import numpy as np


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--bin', required=True, help='Path to the .bin file to mmap')
    p.add_argument('--dtype', default='uint16',
                   help='numpy dtype to view the file as (default: uint16)')
    p.add_argument('--num-iters', type=int, default=200)
    p.add_argument('--slice-len', type=int, default=1024,
                   help='How many elements per random-slice read')
    p.add_argument('--batch-size', type=int, default=4)
    args = p.parse_args()

    print(f"[mmap-only] opening {args.bin} as np.memmap dtype={args.dtype}")
    t0 = time.time()
    arr = np.memmap(args.bin, dtype=np.dtype(args.dtype), mode='r')
    t1 = time.time()
    print(f"[mmap-only] mmap returned in {t1 - t0:.3f}s, size={arr.size} elements "
          f"({arr.nbytes / 1024 / 1024:.1f} MiB)")

    # Random slice reads through the mapped region — touches pages spread
    # across the buffer, so anonymous-backing eager-population is fully
    # exercised.
    random.seed(0)
    total_bytes = 0
    t0 = time.time()
    for step in range(args.num_iters):
        for _ in range(args.batch_size):
            start = random.randint(0, max(0, arr.size - args.slice_len))
            slc = arr[start:start + args.slice_len]
            # force-materialize via .sum() so the pages actually get faulted in
            _ = int(slc.astype(np.int64).sum())
            total_bytes += slc.nbytes
        if step > 0 and step % 50 == 0:
            elapsed = time.time() - t0
            iters_per_sec = (step + 1) / elapsed
            mb_per_sec = total_bytes / (1024 * 1024) / elapsed
            print(f"[mmap-only] step={step}/{args.num_iters} "
                  f"{iters_per_sec:.1f} iters/s, {mb_per_sec:.2f} MB/s")
    elapsed = time.time() - t0
    print(f"[mmap-only] DONE {args.num_iters} iters in {elapsed:.2f}s "
          f"= {args.num_iters / elapsed:.2f} iters/s, "
          f"{total_bytes / (1024 * 1024) / elapsed:.2f} MB/s")

    # Explicitly drop the memmap → munmap on the tracked addr → our
    # munmap wrapper resolves the addr via the tracker and calls the
    # right __real_munmap length.
    del arr
    print("[mmap-only] memmap released")


if __name__ == '__main__':
    main()
