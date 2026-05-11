#!/bin/bash
#SBATCH -p rtx4060ti16g  # Override at sbatch time to a partition whose
                         # node has BOTH a GPU (Horovod) AND a DAX PMem mount.
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_three_tier
#SBATCH -o /home/ghu4/hvac/FitCachePP/benchmarks/results/three_tier/FitCachePP_three_tier-%j.out
#
# Three-tier (DRAM + PMem + NVMe) hardware-evaluation pilot.
# Runs the same CosmoFlow workload as the single-job baseline
# (PDSW_FITPP.sh), but with all three tiers enabled. Reuses the shared
# launcher PDSW_FITPP_inner.sh.
#
# IMPORTANT — before submission:
#   1. Verify the target node has a DAX-mounted PMem volume:
#        ssh <node> 'mount | grep -E "dax|pmem"'
#      If nothing shows, the FitCache_PMEM_PATH directory is just ordinary
#      storage (whatever filesystem hosts /mnt/pmem). The placement code
#      will still exercise the three-tier path, but you won't be measuring
#      PMem performance — you'll be measuring whatever fs is backing that
#      path. The shared local smoke (scripts/run_three_tier_smoke.sh) covers
#      that case already.
#   2. Verify the target node has a GPU. The cluster's CPU-only nodes
#      (e.g. c35 in the `cascade` partition) cannot run CosmoFlow + Horovod.
#      If you need a CPU-only pilot, use scripts/run_three_tier_smoke.sh
#      instead, which exercises the same placement/restore code paths
#      without TensorFlow.
#   3. Override FitCache_PMEM_PATH below if your node's PMem isn't at
#      /mnt/pmem (e.g. /mnt/pmem0/, /dev/dax0.0 via ndctl, etc.).
#
# What this defends:
#   - The opt-in PMem tier (CACHE_TIER_PMEM, FitCache_PMEM_PATH/_CAPACITY)
#     works end-to-end on real PMem hardware (DAX-mounted), not just the
#     ext4-faked local smoke (scripts/run_three_tier_smoke.sh).
#   - Per-tier placement and per-tier eviction behave under a realistic
#     CosmoFlow training I/O pattern (sustained shuffled-read workload
#     across an epoch, with a working set roughly tier-spillable).
#   - The IPDPS two-tier-extrapolation experiment can be replaced with a
#     real three-tier measurement.
#
# Why c35: it is the only node in the cluster confirmed to have a
# DAX-mounted PMem volume at /mnt/pmem (verify with `mount | grep dax`
# before submission; if the path differs, override FitCache_PMEM_PATH below).
#
# Capacities are sized so the CosmoFlow mini training dataset
# (cosmoUniverse_2019_05_4parE_tf_v2_mini, ~tens of GiB) spills across
# the three tiers:
#   DRAM = 20 GiB   (deliberately too small to hold all the hot data)
#   PMem = 60 GiB   (large enough to catch the spill from DRAM)
#   NVMe = 500 GiB  (final landing tier; should remain mostly idle)
# Adjust if `mount | grep pmem` on c35 reports a smaller usable region.
#
# This script just sets up the three-tier env and execs the shared launcher.

NODE_DEFAULT="$(scontrol show hostnames $SLURM_JOB_NODELIST 2>/dev/null | head -1)"
NODE_DEFAULT="${NODE_DEFAULT:-c35}"
export SERVER_NODES="${SERVER_NODES:-$NODE_DEFAULT}"
export CLIENT_NODES="${CLIENT_NODES:-$NODE_DEFAULT}"
export SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
export FitCache_SERVER_COUNT="${FitCache_SERVER_COUNT:-4}"

# Mercury / log4c env (matches build env)
export FitCache_LOG_LEVEL=500
export RDMAV_FORK_SAFE=1
export VERBS_LOG_LEVEL=4
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/rlibrary/miniconda3/envs/hvac_tf/bin:/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH

# Three-tier paths + capacity.
export FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_three_tier_dram
export FitCache_PMEM_PATH=${FitCache_PMEM_PATH:-/mnt/pmem/ghu4/fitcachepp_three_tier_pmem}
export FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_three_tier_nvme
export FitCache_DRAM_CAPACITY=$((20  * 1024 * 1024 * 1024))   # 20 GiB
export FitCache_PMEM_CAPACITY=$((60 * 1024 * 1024 * 1024))    # 60 GiB
export FitCache_NVME_CAPACITY=$((500 * 1024 * 1024 * 1024))   # 500 GiB
# NOTE: parent of train/ + validation/, so the LD_PRELOAD substring filter
# (fitcache_client.cpp:116) catches both. train.py gets the same path via
# --data-dir in command_CF_FITPP.sh.
export FitCache_DATA_DIR=/mnt/beegfs/ghu4/hvac/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440
export BBPATH=$FitCache_NVME_PATH

# Cross-job OFF for this pilot — we're characterising the three-tier
# placement / eviction behavior, not cross-job sharing. The two-job
# cross-job experiments (PDSW_FITPP_two_job_*.sh) cover the sharing claim.
export FitCache_CROSS_JOB=0

export RESULTS_DIR=/home/ghu4/hvac/FitCachePP/benchmarks/results/three_tier
mkdir -p "$RESULTS_DIR"

# Pre-flight: warn if FitCache_PMEM_PATH doesn't exist or isn't writable.
# Don't abort — the data mover will fall back to two-tier behavior, which
# defeats the experiment but doesn't break the job. The warning makes the
# fallthrough visible in the .out file.
if [ ! -d "$FitCache_PMEM_PATH" ]; then
    echo "[warn] FitCache_PMEM_PATH=$FitCache_PMEM_PATH does not exist; attempting mkdir"
    mkdir -p "$FitCache_PMEM_PATH" || \
        echo "[warn] mkdir failed; PMem tier will be DISABLED for this run"
fi
if [ ! -w "$FitCache_PMEM_PATH" ]; then
    echo "[warn] FitCache_PMEM_PATH=$FitCache_PMEM_PATH is not writable; PMem tier will be DISABLED"
fi
echo "[setup] DRAM=$FitCache_DRAM_PATH (cap=$FitCache_DRAM_CAPACITY)"
echo "[setup] PMem=$FitCache_PMEM_PATH (cap=$FitCache_PMEM_CAPACITY)"
echo "[setup] NVMe=$FitCache_NVME_PATH (cap=$FitCache_NVME_CAPACITY)"
mount 2>/dev/null | grep -E "pmem|dax" | sed 's/^/[mount] /'

exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
