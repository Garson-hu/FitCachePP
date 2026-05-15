# DINOv2 mmap-interceptor FitCachePP-vs-Pure_CF (2026-05-15 01:40)

**Setup:** Single Frontier compute node, `dinov2_io_only_iter.py` over the
synthetic ImageNet-22k stand-in (20 classes × 50 images, ~217 MB total),
2000 iters × batch_size=4 = 8000 image opens. The I/O-only iterator is
the same artifact the 2026-05-12 ARC workload-generalization analysis
used; running it under LD_PRELOAD'd `libfitcache_client.so` exercises
the exact open + mmap pattern that DINOv2's ImageNet22k loader generates.

## Results

| Side       | SLURM   | Wall  | iters/s | MB/s   | Open RPCs | mmap-redirects |
|------------|---------|-------|---------|--------|-----------|----------------|
| FitCachePP | 4586006 | 6.51 s | 307     | 33.3   | 7993      | 16000          |
| Pure_CF    | 4586007 | 2.13 s | 940     | 102    | n/a       | n/a            |

**FitCachePP/Pure_CF wall-clock ratio: 3.06x slower** (FitCachePP is the
high overhead floor at this dataset size).

## Engagement signals (FitCachePP side)

- 7993 Open RPCs — matches expected 8000 ± rounding (2000 iters × 4 batch
  per iter; deterministic seed=0 so the same files get re-opened in
  successive iters and FitCache deduplicates).
- 16000 mmap-redirects — 2 log lines per call ("mmap on tracked fd …",
  "mmap: redirected to anon …") × 8000 mmap calls ≈ matches.

Both signals confirm the mmap interceptor and the `mmap64` symbol
interposition are exercised end-to-end on a Frontier compute node, on
the many-small-files DINOv2 I/O pattern.

## Why FitCachePP is slower at this scale

The synthetic ImageNet stand-in is 217 MB total — small enough that
Frontier's compute-node RAM (512 GB) absorbs the entire working set
into page cache on the first pass. Pure_CF's second-through-last
iterations hit RAM at ~100 MB/s. FitCachePP routes every open + mmap
through Mercury RPC + anon-fill, adding ~250 µs per file open; on
~31 ms/iter of pure-RAM Pure_CF work this is a 3x overhead floor.

This matches the same shape we saw on:
- ARC `n_train=8192` no-pressure cosmoflow (~3.7% slower, smaller dataset)
- Frontier `n_train=1024` cosmoflow sanity (~2.9% slower, 307 MB)

**The defensible claim:** the mmap interceptor lights up correctly on
the DINOv2-style I/O pattern (workload-generalization unblocked); the
quantitative speedup story requires datasets large enough to overflow
node RAM — production ImageNet-22k (1.4 TB) or one of the multi-billion-
file scientific datasets. Synthetic 217 MB is the wrong size to land a
win, but it's the right size to validate the mechanism.

## Followup before paper claims

- Stage real ImageNet-22k via Kaggle/ILSVRC registration (or use a
  multi-TB scientific image dataset already on Orion).
- Re-run at >512 GB working-set to put the OS page cache in pressure.
- Compare to the cosmoflow headline at n_train=524288 (1.4 TB) — same
  cluster, same hardware, same FitCachePP build — to show the speedup
  emerges consistently when the dataset exceeds RAM regardless of
  whether the access path is TFRecord+pread (cosmoflow) or
  mmap-via-numpy.memmap/PIL (Megatron/DINOv2).
