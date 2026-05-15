#!/usr/bin/env python3
"""
dinov2_io_only_iter.py

I/O-shape probe for the DINOv2 / ImageNet22k workload. Walks an
ImageNet-style directory tree (one class subdir per node, JPEGs inside)
and for each image:

    1. open(path)        — picked up by FitCache open wrapper
    2. mmap(fd, ...)     — picked up by FitCache mmap interceptor
    3. read pixels       — forces page-faults / anon-fill into the mapping

Mirrors DINOv2's per-image mmap+decode pattern without bringing in the
full DINOv2 training stack. Sufficient to exercise libfitcache_client's
many-small-files codepath.

Usage:
    LD_PRELOAD=libfitcache_client.so python dinov2_io_only_iter.py \\
        --root /lustre/orion/gen008/proj-shared/ghu4/data/dinov2/imagenet_synth \\
        --num-iters 200
"""
import argparse
import mmap
import os
import random
import sys
import time


def walk_images(root):
    out = []
    for dirpath, _, files in os.walk(root):
        for f in files:
            if f.endswith(('.jpg', '.jpeg', '.JPEG', '.png')):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', required=True,
                   help='ImageNet-style root: <root>/<class>/<image>.jpg')
    p.add_argument('--num-iters', type=int, default=200,
                   help='Number of image-open iterations')
    p.add_argument('--batch-size', type=int, default=4)
    args = p.parse_args()

    files = walk_images(args.root)
    if not files:
        print(f"[dino-io] no images under {args.root}", file=sys.stderr)
        return 2
    print(f"[dino-io] found {len(files)} images under {args.root}")

    random.seed(0)
    total_bytes = 0
    t0 = time.time()
    for step in range(args.num_iters):
        for _ in range(args.batch_size):
            path = random.choice(files)
            # Open + mmap + read every page (touch the buffer).
            # Using mmap.mmap directly via Python's stdlib mmap module —
            # which goes through libc mmap64 → our LD_PRELOAD'd wrapper.
            fd = os.open(path, os.O_RDONLY)
            size = os.fstat(fd).st_size
            mm = mmap.mmap(fd, size, prot=mmap.PROT_READ)
            try:
                # Force-touch a few pages so the anonymous-fill path is
                # exercised when the wrapper intercepts. Cheaper than full
                # decode — we're testing I/O, not image decoding.
                _ = mm[0:min(4096, size)]
                _ = mm[size // 2: min(size // 2 + 4096, size)]
                _ = mm[max(0, size - 4096): size]
                total_bytes += size
            finally:
                mm.close()
                os.close(fd)
        if step > 0 and step % 50 == 0:
            elapsed = time.time() - t0
            iters_per_sec = (step + 1) / elapsed
            mb_per_sec = total_bytes / (1024 * 1024) / elapsed
            print(f"[dino-io] step={step}/{args.num_iters} "
                  f"{iters_per_sec:.1f} iters/s, {mb_per_sec:.2f} MB/s")
    elapsed = time.time() - t0
    print(f"[dino-io] DONE {args.num_iters} iters in {elapsed:.2f}s "
          f"= {args.num_iters / elapsed:.2f} iters/s, "
          f"{total_bytes / (1024 * 1024) / elapsed:.2f} MB/s "
          f"({total_bytes / 1024 / 1024:.1f} MB total)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
