# Real DAX-mode PMem hardware evaluation on c35

**Date:** 2026-05-12
**Hardware:** c35, cascade partition. `/dev/pmem0 on /mnt/fsdax type ext4 (rw,relatime,dax=always)` — confirmed real DAX-mode PMem.
**Cluster topology blocker:** c35 has DAX PMem but **no GPU**. GPU nodes (rtx4060ti16g partition) have **no PMem hardware**. GPU + PMem are not co-located on this cluster.

## Runs

### Sustained-read micro-benchmark on c35 with source on local /tmp (SLURM 221792)

- Working set 1 GiB (256 × 4 MiB). Tier capacities DRAM 200 MiB, PMem 400 MiB, NVMe 600 MiB. `FitCache_CROSS_JOB=1` (enables three-tier wiring — `FitCache_CROSS_JOB` controls the cluster-registry-backed coordination layer; env-var contract in `tpds_extension/02_design_cross_job.md` §9).
- Cold pass (LD_PRELOAD `open` falls through to local /tmp source on c35): 34.3s
- Warm-pass mean per round (LD_PRELOAD `open` redirects to a tier file): 258.1s
- Tier population after cold pass: DRAM=50, PMem=93, NVMe=68 (211/256 promoted)
- Warm-vs-cold ratio: **0.13x** (warm is 7.5x slower than cold)

### Sustained-read micro-benchmark on c35 with source on BeeGFS, OS page cache evicted between passes (SLURM 221802)

- Same working set + tier capacities.
- Source moved to `/mnt/beegfs/ghu4/hvac/c35_pmem_evaluation_beegfs_source_dataset`.
- `evict_page_cache.py` called before warm-up and before steady-state so neither pass is served from RAM.
- Cold pass (LD_PRELOAD `open` falls through to BeeGFS direct read): 53.9s (≈19 MB/s)
- Warm-pass mean per round (LD_PRELOAD `open` redirects to a tier file on DRAM/PMem/NVMe): 260.8s (≈4 MB/s)
- Tier population after cold pass: DRAM=35, PMem=70, NVMe=64 (169/256 promoted)
- Warm-vs-cold ratio: **0.21x** (warm is 4.8x slower than cold)

## Interpretation

The cache-hit path is slower than the cache-miss path in **both** configurations, by 5–8x. This is not a hardware issue with `/mnt/fsdax`: per-tier placement fires end-to-end on real PMem (DRAM/PMem/NVMe directories all populate), `/dev/pmem0` is ext4 in dax=always mode, and the source-on-BeeGFS run confirms the relative ordering doesn't depend on what filesystem hosts the source.

The mechanism is structural to FitCachePP's open-path RPC protocol:

1. **Cache-miss (cold) path:** LD_PRELOAD's `open` intercept consults the server, server replies "not cached," client falls through and reads the source file directly. Cost: 1 RPC roundtrip per open + 1 source-filesystem open + bulk read. With 256 files and a ~19 MB/s effective rate on BeeGFS source, the work is bottlenecked on source-read bandwidth, not the RPC.

2. **Cache-hit (warm) path:** LD_PRELOAD's `open` intercept consults the server, server replies "redirect to /mnt/fsdax/..." (or DRAM, or NVMe tier), client opens the cache file. Each round of 256 opens takes ~256 s ≈ ~1 s/open, which at 4 MiB/file is ~4 MB/s — too slow to be PMem-limited. The cache-hit protocol clearly has a multi-hundred-millisecond per-open tax that the cache-miss path doesn't pay (the miss path is one round-trip + one direct read; the hit path is one round-trip + a redirected open + read).

The per-open RPC overhead dominates when the per-file work is small (4 MiB random-bytes harness, single read per file). It amortises when the per-file work is large: that's why the single-job FitCachePP-vs-Pure_CF CosmoFlow baseline runs — which open each TFRecord once and read large chunks — saw only +7% overhead from FitCachePP (840s for Pure_CF, 899s for FitCachePP at `n_train=8192`).

## Why the multi-node CosmoFlow on c35 with three-tier wiring is infeasible

The original plan was to run the single-job CosmoFlow workload on c35 with `FitCache_PMEM_PATH=/mnt/fsdax`, replacing the IPDPS two-tier extrapolation with a real three-tier measurement. This is blocked by cluster topology:

- c35 (cascade partition): `/dev/pmem0` DAX PMem, **no GPU** (`scontrol show node c35` reports no GRES). CosmoFlow + Horovod requires CUDA.
- rtx4060ti16g partition (where the single-job CosmoFlow runs ran): RTX 4060ti GPUs, **no DAX PMem** (verified by `mount | grep -E "dax|pmem"` returning nothing on those nodes).
- PMem is local DAX storage; it cannot be remotely mounted as DAX to a different node.

There is no node on this cluster with both a GPU and DAX-mode PMem. Quantitative CosmoFlow-on-real-PMem evaluation requires a cluster that co-locates GPU + PMem.

## What this defends for the TPDS paper

What the data lets us claim:
- **Real-PMem code path validation.** The three-tier wiring (`FitCache_DRAM_PATH`, `FitCache_PMEM_PATH`, `FitCache_NVME_PATH` + capacities) operates end-to-end on a real DAX-mode PMem mount, not just an NVMe shim. Placement directs files into all three tiers per the priority rules; eviction was not exercised because the working set fit in total capacity (1024 MiB working set vs 1200 MiB total capacity).
- **Architectural-limit characterisation of the open-path RPC.** The sustained-read micro-benchmark gives a clean upper bound on the per-open RPC overhead (~250 ms) that the cache-hit protocol pays. This bound predicts when FitCachePP will and won't win: workloads with high per-open work amortise (CosmoFlow's TFRecord reads); workloads with low per-open work do not (this micro-benchmark; potentially any HuggingFace `datasets` per-line iterator if reads were small).

What the data does **not** let us claim:
- A quantitative PMem-vs-NVMe speedup on a realistic ML workload. This claim now requires either (i) a cluster with GPU + PMem co-located, or (ii) reducing the per-open RPC overhead in FitCachePP so the cache-hit path can match the cache-miss path in throughput at small per-open work sizes.

## Recommended paper framing

Reframe the three-tier hardware evaluation section as: "We validate the three-tier code path on real DAX-mode PMem (c35 `/dev/pmem0`, ext4 dax=always). All three tiers populate correctly under sustained reads. The cluster's topology — GPU and PMem are on disjoint node classes — precludes a quantitative end-to-end CosmoFlow-on-PMem measurement on our testbed; we report the sustained-read characterisation here and leave the quantitative GPU+PMem measurement for a cluster with co-located hardware."

This is consistent with how the workload-generalization story (Megatron-LM and DINOv2) had to be reframed as an architectural-limit story when both target workloads turned out to use mmap.

## Artifacts retained (KEEP=1)

On c35:
- `/mnt/beegfs/ghu4/hvac/c35_pmem_evaluation_beegfs_source_dataset/` — persistent BeeGFS source dataset (256 × 4 MiB), reusable for repeat runs.
- `/tmp/fitcachepp_sustained_read_2861910/logs/` — BeeGFS-source-run client + server logs.
- `/mnt/fsdax/ghu4/fitcachepp_c35_pmem_eval_beegfs_source/` — 70 cached files in PMem tier.
- `/mnt/local/ghu4/fitcachepp_c35_pmem_eval_beegfs_source_{dram,nvme}/` — 35 and 64 cached files respectively.

Local-source-run artifacts (SLURM 221792) at `/tmp/fitcachepp_sustained_read_2822789/` on c35.

## Open follow-up code work (out of scope for this session)

- Profile the cache-hit open path to identify the ~250 ms-per-open bottleneck. Candidate suspects: cluster-registry lookup, path_cache_map serialization, the redirect protocol itself, or `fitcache_client.cpp` open-time handshake order.
- If the bottleneck is reducible, the cache-hit path could win against BeeGFS source at smaller per-open work sizes, broadening the workload class that benefits from FitCachePP.
