# Single-job FitCache++ baseline (SLURM 221607)

**Date:** 2026-05-11 04:00 – 04:19 UTC
**Node:** c66 (rtx4060ti16g partition)
**Mode:** FitCache_CROSS_JOB=0 (cross-job extension paths inert)
**Workload:** CosmoFlow on `cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440/train/`
  512 steps/epoch, batch_size=2, 5 epochs, 1 GPU
**Server topology:** 4 FitCache++ servers on c66, FitCache_DRAM_CAPACITY=100GB, FitCache_NVME_CAPACITY=500GB
**Wall-clock (sacct):** 19m00s end-to-end (servers up + 5 epochs + teardown)

## Per-epoch times

| Epoch | Time (s) | Notes |
|---:|---:|---|
| 1 | 362 | cold — fills cache from PFS |
| 2 | 189 | warm |
| 3 | 188 | warm |
| 4 | 188 | warm |
| 5 | 186 | warm |
| **sum** | **1113** | training time only |

Cold/warm speedup: 362s → 188s ≈ **1.93x** (matches the IPDPS PDSW_FIT shape — confirms the cache is doing its job).

## Cross-job paths quiescent in single-job mode

Greps across all four server logs (`server_221607_id{0,1,2,3}.log`):

| Counter | Value | Expected |
|---|---:|---|
| `peer_lookup: rank=` queries handled | 0 | 0 (no peers in registry; cross-job=0) |
| sidecar writes ("Data mover: wrote sidecar") | 0 | 0 (sidecars only when cross-job=1) |

**Confirms the zero-regression-vs-IPDPS-single-job claim at the shape
level:** training completes, cache cold/warm ratio matches expectations,
and every cross-job code path correctly stays inert. The bit-identical
form of the claim would require running the same data twice with
`CROSS_JOB=0` and `CROSS_JOB=1` (no peers) and hashing the cached files;
that's the deferred unit-test-scale bit-equivalence harness.

## Files

- `FitCachePP-221607.out` — SLURM stdout (Horovod + train.py output)
- `server_221607_id0.log` ... `server_221607_id3.log` — per-server stderr
- `horovodrun_221607.log` — horovodrun teed output (currently empty; the
  redirection was added to `PDSW_FITPP_inner.sh` after this run, so 221607
  has no separate horovod log)
