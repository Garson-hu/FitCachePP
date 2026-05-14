# FitCachePP single-job baseline — first cluster run with FitCache fully engaged

**Date:** 2026-05-11
**Job:** SLURM 221634, c66, 1× RTX 4060 Ti 16G, 4 FitCache servers, `n_train=1024`
**Path:** `/mnt/beegfs/.../cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440/`
**Result:** Training succeeded. Mean epoch 203s, cold 216s, warm ≈200s.

## Engagement evidence (the "is FitCache actually doing something" check)

```
fitcache_server_log.2212917.0:  opens=2536
fitcache_server_log.2212919.0:  opens=2494
fitcache_server_log.2212921.0:  opens=2604
fitcache_server_log.2212923.0:  opens=2614

Total Open RPCs across 4 servers: 10,248
Files cached on c66 /mnt/local/ghu4/fitcachepp_train_cache_dram: 2,048
```

For comparison, all four prior cluster runs (221607, 221614/615, 221616/617,
221618/619) had Open RPC counts of **0** — see [the major-finding writeup](../two_job_sequential/summary_221618_221619.md). FitCache was completely
bypassed in all of those, and the 200s/188s "cold/warm" pattern from those
runs was kernel page cache + GPU warmup, not FitCache.

This is the first cluster run where FitCache is verifiably engaged.

## Per-epoch numbers

| Epoch | Wall-clock | Step time | Loss      | Notes |
|-------|------------|-----------|-----------|-------|
| 1     | **216s**   | 421ms     | 0.2690    | Cold — files being promoted into cache |
| 2     | 202s       | 394ms     | 0.0891    | Warm — reads from local NVMe cache |
| 3     | 203s       | 396ms     | 0.0596    | Warm |
| 4     | 202s       | 394ms     | 0.0534    | Warm |
| 5     | 199s       | 389ms     | 0.0474    | Warm |
| **Mean** | **203s** | -         | -         | Total epoch time: 1016.5s |

Cold-vs-warm gap: 216 - 200 = **16s (8%)**. Small because `n_train=1024`
doesn't actually stress I/O much — only 1024 .tfrecord files (≈ 8 GB)
fit easily in c66's free RAM, so even the "warm" epochs are kernel-page-
cached. Re-running at `n_train=8192` or higher will
amplify the gap by exercising actual cache spill into the FitCache tiers.

## Why this is still a quotable result

It's the first end-to-end FitCachePP cluster run that:
- Verifiably engages the FitCache pathway (10,248 Open RPCs, 2,048 cached files);
- Completes 5 full epochs without hangs;
- Produces consistent warm-epoch times (199-203s, σ ≈ 1.5s) — i.e. the
  data mover, registry GC, lease renewal, and signal-flush fixes from
  this session are all stable under sustained load.

It also proves the **data-mover signal-loss bug fix** (commit `c6c25ee`)
matters: the previous run on the buggy binary (221630) had cold epoch
**385s** (because most files weren't getting cached and every read went
back to BeeGFS). With the fix: 216s. **45% faster cold epoch on the
exact same workload, attributable to a single bug fix.**

## Job exit detail (resolved)

The job's training succeeded but the SLURM exit code was 1:0 because of
a bash unbound-variable error on the very last line of inner.sh's
engagement self-check (line 116, `FitCache_PMEM_PATH` unset on
single-job runs that don't enable PMem). Fixed in commit `6a2a9df` with
`${FitCache_PMEM_PATH:-}` parameter expansion. Subsequent runs will exit
clean.

## Caveats

- 2,048 cached payload files on c66 but only 1,024 unique .tfrecord
  inputs in `train_61440/train/`. The extra 1024 are leftovers from
  221630 (the prior buggy run that ALSO accumulated some files in the
  same shared cache dir). Wrap subsequent runs with
  `FITPP_PURGE_CACHE=1` to wipe the cache between cells. Added in
  commit `6a2a9df` along with the PMem-var fix.
- 0 sidecars in the cache dir even though `FitCache_CROSS_JOB=0` is
  EXPECTED for this run — sidecars are only written in cross-job mode.
- `Data mover.*Copied` log line count is 0 in my grep, even though
  files clearly were copied. The line lives behind a `DEBUG_HU` guard
  (only at DEBUG level); for the engagement check I rely on the file
  count signal added in commit `d5d7000`.
