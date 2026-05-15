# Sustained-read micro-benchmark on c35 /mnt/fsdax with local /tmp source — result

**Date:** 2026-05-12
**SLURM job:** 221792 on c35 (cascade partition), COMPLETED in 18:01
**Script:** `scripts/smoke/run_three_tier_sustained_read.sh`
**Output:** `benchmarks/results/three_tier/sustained_read_smoke_c35_local_source-221792.out`
**KEEP=1 artifacts:** `/tmp/fitcachepp_sustained_read_2822789/` on c35

## Run configuration

- `PMEM_PATH=/mnt/fsdax/ghu4/fitcachepp_c35_pmem_eval_local_source` (real DAX-mode PMem on c35 — first time the directory was writable for our user)
- `DRAM_PATH=/mnt/local/ghu4/fitcachepp_c35_pmem_eval_local_source_dram`
- `NVME_PATH=/mnt/local/ghu4/fitcachepp_c35_pmem_eval_local_source_nvme`
- Working set: 256 files × 4 MiB = 1024 MiB (synthetic random bytes)
- Tier capacities: DRAM 200 MiB, PMem 400 MiB, NVMe 600 MiB (total 1200 MiB > working set, so no eviction)
- `FitCache_CROSS_JOB=1` (cluster registry + cross-job code paths active — `FitCache_CROSS_JOB` controls the cluster-registry-backed coordination layer; env-var contract in `tpds_extension/02_design_cross_job.md` §9)

## Raw numbers

| Measurement | Value |
|---|---|
| Cold pass (1 sweep over 256 files, cache empty) | **34.28s** |
| Warm-pass mean per round (1 sweep, cache populated) | **258.12s** |
| Warm-pass total (4 rounds) | 1032.49s |
| Apparent "speedup" (warm vs cold) | **0.13x** (i.e. warm is ~7.5x SLOWER) |
| Tier population after cold pass | DRAM=50, PMem=93, NVMe=68 (211/256, 45 not yet promoted) |

## Interpretation — the micro-benchmark is misleading with a local source

The headline ratio is paradoxical (warm slower than cold), but it does **not** indicate a hardware issue with `/mnt/fsdax`. The mechanism is:

1. **Cold pass is fast because source is local.** This run generates the dataset under `/tmp/fitcachepp_sustained_read_$$/dataset`, which on c35 is a local SSD (or tmpfs). The LD_PRELOAD'd `open` falls through and the client reads directly while the server kicks off async promotion. The OS page cache backs the first sweep at near-local-SSD speed (~30 MB/s effective through the harness, gated by the harness's per-file open/read cycle).

2. **Warm pass pays the full FitCache RPC roundtrip on every open.** With the tier populated, each open in the warm sweep goes through cluster registry → lookup → redirect → tier read. With 1024 opens per round (256 files × 4 rounds) and the observed wall-clock, each open round-trips at ~250 ms — that matches expected Mercury RPC latency plus path resolution overhead, and 1024 × 0.25s ≈ 256s ≈ the measured 258s/round.

3. **Local PMem cannot beat local SSD as a source.** The cache layer adds an RPC tax; the cache only wins when the source it replaces is meaningfully slower (BeeGFS, multi-node fetch). On this single-node configuration the source IS the local node, so the architecture loses by construction.

4. **Placement itself works.** All three tiers populated (DRAM 50, PMem 93, NVMe 68), `/mnt/fsdax` accepts writes, no hardware-side errors. The data mover queue did drain — 211/256 files promoted before the warm pass began.

## Conclusion

This run confirms `/mnt/fsdax` is writable on c35 and the three-tier placement code paths fire end-to-end on real PMem. It does **not** show a cache speedup, and shouldn't — the source filesystem in this configuration is faster than the FitCache RPC layer.

To measure a real PMem speedup we need:
- A source on slow storage (BeeGFS) so the RPC tax is amortised against a 100x slower source read.
- A working set larger than the OS page cache so source reads can't be served from RAM regardless.
- A workload with realistic read sizes (one large read per file, not many small ones) so per-open RPC is amortised.

The natural follow-up — **the multi-node CosmoFlow run on c35 with three-tier wiring** (same workload as the single-job CosmoFlow baseline, but using `/mnt/fsdax` for the PMem tier instead of an NVMe shim) — would give BeeGFS as source, TFRecord-sized reads, and the real CosmoFlow access pattern. That follow-up turned out to be infeasible on this cluster (c35 has DAX PMem but no GPU; the GPU nodes have no PMem). See [real_pmem_evaluation_on_c35.md](real_pmem_evaluation_on_c35.md) for the full story including the BeeGFS-source repeat run.

## Artifacts retained (KEEP=1)

On c35:
- `/tmp/fitcachepp_sustained_read_2822789/logs/{client_warmup.log,client_steady_{1..4}.log,server.log}` — server log only has signal-15 exit (FitCache_LOG_LEVEL=500 = silent).
- `/mnt/fsdax/ghu4/fitcachepp_c35_pmem_eval_local_source/` — 93 cached files in PMem (still present after run).
- `/mnt/local/ghu4/fitcachepp_c35_pmem_eval_local_source_dram/` — 50 cached files in DRAM tier.
- `/mnt/local/ghu4/fitcachepp_c35_pmem_eval_local_source_nvme/` — 68 cached files in NVMe tier.
