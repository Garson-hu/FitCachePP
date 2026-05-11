# Three-tier placement + restoration smoke (local, no PMem hardware)

**Date:** 2026-05-11
**Script:** `scripts/run_three_tier_smoke.sh`
**Result:** PASS

## What this defends

The three-tier (DRAM + PMem + NVMe) placement decision and the
sidecar-driven restoration loop, before burning a cluster allocation on the
PMem-equipped node. PMem here is faked with a regular ext4 directory — the
placement / sidecar / eviction code doesn't care whether the path is
DAX-mounted, it just writes through the filesystem API. So a passing local
smoke proves the FitCachePP changes are sound; the c35 pilot then proves
the runtime performance of DAX-PMem.

## Method

12 files of 1 MiB each. Tier capacities set to 4 MiB each, so placement
must spill DRAM → PMem → NVMe in order.

```
FitCache_DRAM_PATH=/tmp/.../dram     FitCache_DRAM_CAPACITY=4 MiB
FitCache_PMEM_PATH=/tmp/.../pmem     FitCache_PMEM_CAPACITY=4 MiB
FitCache_NVME_PATH=/tmp/.../nvme     FitCache_NVME_CAPACITY=4 MiB
```

Pass 1: server starts with `FitCache_CROSS_JOB=1`. Client opens & reads all
12 files; data mover places them into the three tier dirs. Sidecars get
written next to each cached file.

Pass 2: same server binary restarts pointing at the same tier dirs. The
restore-sidecars loop must scan all three tier roots and rebuild
`path_cache_map`.

## Observed

Pass 1 placement counts:
```
dram=4  pmem=4  nvme=4   (total=12)
```

Pass 2 restoration log lines:
```
restore-sidecars: restored 4 files from DRAM tier /tmp/.../dram
restore-sidecars: restored 4 files from PMem tier /tmp/.../pmem
restore-sidecars: restored 4 files from NVMe tier /tmp/.../nvme
restore-sidecars: total restored = 12
```

All three tiers populated; all three tiers rebuilt from sidecars. The PMem
code paths in `fitcache_data_mover_fn` (placement) and
`fitcache_data_mover_restore_from_sidecars` (restoration) are exercised
end-to-end.

## Backward-compatibility check

The bit-equivalence smoke
(`scripts/run_bit_equivalence_smoke.sh`) was re-run after the PMem changes
landed. It still passes with `FitCache_CROSS_JOB={0,1}` producing
byte-identical cache content — i.e. the PMem code path is dormant when
`FitCache_PMEM_PATH` is unset, and the zero-regression-vs-IPDPS claim is
preserved.
