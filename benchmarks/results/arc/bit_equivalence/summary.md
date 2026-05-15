# Bit-equivalence smoke result

**Date:** 2026-05-11
**Script:** `scripts/smoke/run_bit_equivalence_smoke.sh`
**Result:** PASS

## What this defends

Zero-regression-vs-IPDPS-single-job claim, byte-level. With `FitCache_CROSS_JOB`
unset or `=0`, the FitCachePP single-job code path must produce identical
cached file contents to the FitCachePP single-job path with `FitCache_CROSS_JOB=1`
(when only one server is live, so the peer-lookup fanout never fires). Both
must match the original source bytes.

## Method

1. Generate 8 source files of 256 KiB each (random bytes) under
   `/tmp/fitcachepp_bit_equiv_<pid>/dataset/`.
2. Pass `off`: spawn one `fitcache_server` with `FitCache_CROSS_JOB=0` and a
   fresh DRAM+NVMe cache tree. Drive `tests/harness_read_files` via
   `LD_PRELOAD=libfitcache_client.so` so every file is opened, read, and
   promoted into the cache tier. Tear down server.
3. Pass `on`: same workload, fresh cache tree, but `FitCache_CROSS_JOB=1`.
   Single server → no peer-lookup ever fires (the local live set has
   exactly itself), so we exercise the HRW + slot table + dataset_id /
   subscriber-lease publish paths without invoking redirect.
4. `sha256sum` every cached `file_*.bin` in both DRAM and NVMe trees from
   each pass. Compare against the source `sha256sum`.

## Outcome

All 24 hashes (8 source + 8 off-pass cache + 8 on-pass cache) match:

```
2aa1991d94640b33829578323eeb5c1e5cf6ccecc287ce7d50975cb1e48847d7 file_0.bin
3d6e65854c3bdbd322a40e7e13fc43fb0537fcb10a66aa640598fad4d3b508b2 file_1.bin
99f87d5a3ae3ae74e2e0be84994a270faae0ece5839705155823203087b48603 file_2.bin
83d64602c7a0a704a679615ebd0bd5fb90d3aea1260c8b28d0e2af851af9b718 file_3.bin
5e2b174be969010c9f8028e6a81f54e49a71e2c3b0a79732996f05d90e366425 file_4.bin
601623dabf3b4d962d5d04cda187d728af2ea2fb4e7cff6ee17d0ce30b40f477 file_5.bin
233eb80fc3ec6eb6a40d4fc87882ad2d3877d16021b09bca1c6d8ca285f85b6a file_6.bin
63c1492b1aeba42e6d1e67f87d6bae831ab1125f6dad6b65dd254f690a10914b file_7.bin
```

## Observed mode differences (expected)

- `FitCache_CROSS_JOB=0`: cache contains only the file payloads
  (`./<aa>/<bb>/file_N.bin` content-hash-bucketed layout, no sidecars).
- `FitCache_CROSS_JOB=1`: same payload tree, plus one `.meta` sidecar per
  file (`file_N.bin.meta` next to each payload). These sidecars hold the
  cross-job durable metadata (original path, dataset_id, tier, size,
  promotion time) used by `fitcache_data_mover_restore_from_sidecars`
  at server startup. Absent from the bit-equivalence comparison by design:
  the comparison is over payload bytes, not metadata side-state.

## Caveats

- Single-host, single-process smoke. Defends correctness of the cache
  payload contents under both `CROSS_JOB` settings, not the full cluster
  cross-job protocol. The full protocol is exercised separately by
  `scripts/smoke/run_two_server_smoke.sh` (peer-lookup + redirect) and the
  cluster experiments under `benchmarks/cosmoflow/TPDS_FITPP_two_job_*.sh`.
- NVMe tier is empty in this run because the 2 MiB dataset fits entirely
  in the 100 MiB DRAM budget; no eviction is triggered. A larger smoke
  would exercise tier-spill, but tier-spill correctness is orthogonal to
  the bit-equivalence claim — the tier-spill code path is shared between
  `CROSS_JOB={0,1}`.
