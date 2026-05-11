# c35 PMem hardware probe (2026-05-11)

## Findings

c35 (`cascade` partition, CPU-only) has PMem hardware but it is **not
currently mounted as a filesystem**. From `srun -p cascade -w c35 -- ndctl list`:

```json
[
  {
    "dev": "namespace1.0",
    "mode": "devdax",
    "size": 541163782144,    // ~503 GiB
    "chardev": "dax1.0"
  },
  {
    "dev": "namespace0.0",
    "mode": "fsdax",
    "size": 532708065280,    // ~496 GiB
    "blockdev": "pmem0"
  }
]
```

- `pmem0` (fsdax, 496 GiB) can be mounted as a regular filesystem with the
  `dax` mount option (`mount -o dax /dev/pmem0 /mnt/pmem` — root only).
- `dax1.0` (devdax, 503 GiB) is a character device, exposed via mmap, and
  not directly mountable as a filesystem.
- Neither is mounted: `mount | grep -E "dax|pmem"` returned nothing.

`nvidia-smi -L` on c35 returned nothing — **no GPU on c35**.

## Implication for the three-tier evaluation

**P1-8 (run sustained-read on c35 with real PMem) is blocked on a sysadmin
action:** someone with root needs to `mount -o dax /dev/pmem0 /mnt/pmem`
(or wherever — adjust `FitCache_PMEM_PATH` to match). Once mounted, the
sustained-read smoke at `scripts/run_three_tier_sustained_read.sh` can be
run via `srun -p cascade -w c35` with
`PMEM_PATH=/mnt/pmem/ghu4/fitcachepp_three_tier_pmem` to characterise
real DAX-PMem performance vs NVMe.

**P1-9 (find a node with BOTH GPU and PMem)** — not visible from the
nodes we've probed (c35 has PMem but no GPU; c66/c70/c71 in rtx4060ti16g
have GPU but we couldn't probe for PMem because the partition is full).
Probably no single-node intersection exists on this cluster. Two
mitigations:

1. **Drop CosmoFlow-on-three-tier from the campaign.** Run the
   sustained-read characterisation on c35 (CPU-only) as the three-tier
   evidence — sufficient to defend the tier-spill correctness + PMem
   latency claim. The CosmoFlow + cross-job-sharing evaluations stay on
   the GPU nodes (two-tier).
2. **Run CosmoFlow on c35 in CPU-only mode.** Possible (Horovod
   supports CPU training) but the per-epoch wall blows up by ~10× and
   the comparison vs the GPU baseline becomes apples-to-oranges.

Recommendation: pick (1). The IPDPS evaluation already established the
GPU-CosmoFlow + two-tier numbers; the three-tier story is about the
*placement / eviction / PMem-tier* code paths, which the sustained-read
exercises without TensorFlow in the way.

## Status

- P1-8: **blocked** on root mounting `/dev/pmem0` on c35.
- P1-9: **closed** — recommend dropping the CosmoFlow-three-tier
  combination; use sustained-read on c35 as the three-tier evidence
  once P1-8 is unblocked.
