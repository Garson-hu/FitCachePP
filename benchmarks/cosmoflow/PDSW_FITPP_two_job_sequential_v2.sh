#!/usr/bin/env bash
#
# PDSW_FITPP_two_job_sequential_v2.sh
#
# Phase B.2 driver: submit two FitCachePP single-node jobs SEQUENTIALLY on
# the SAME GPU node (Job B depends on Job A via --dependency=afterok),
# both with the SAME local cache paths. Tests sidecar persistent metadata
# restoration: when Job B's server starts on the same node Job A used,
# the data mover should scan the local cache dir, find Job A's sidecars,
# and rebuild path_cache_map from them. Job B's epoch 1 should then
# behave like a "warm" epoch (~895s) instead of a "cold" epoch (~934s).
#
# This is a DIFFERENT mechanism than Phase B.1 (concurrent peer_lookup):
# - B.1 = two jobs on different nodes, share live-set via peer_lookup RPC
# - B.2 = two jobs same node sequentially, share via on-disk sidecars
#
# Submission:
#   bash PDSW_FITPP_two_job_sequential_v2.sh
# Defaults: NODE=c66, n_train=8192. Override via env.

set -u
set -o pipefail

NODE="${NODE:-c66}"
N_TRAIN="${FITPP_N_TRAIN:-8192}"

REPO=/home/ghu4/hvac/FitCachePP
RESULTS_DIR_BASE="$REPO/benchmarks/results/two_job_sequential_v2"
mkdir -p "$RESULTS_DIR_BASE"

RUN_TAG=$(date +%Y%m%d_%H%M%S)_$$
SHARED_REGISTRY=/mnt/beegfs/ghu4/fitcachepp_registry_two_job_sequential_v2/$RUN_TAG
mkdir -p "$SHARED_REGISTRY"

# Both jobs use the SAME local cache so Job B's server scans Job A's sidecars
# at startup. RUN_TAG is in the path so different runs of this script don't
# step on each other's caches.
SHARED_DRAM=/mnt/local/ghu4/fitcachepp_seqv2_${RUN_TAG}_dram
SHARED_NVME=/mnt/local/ghu4/fitcachepp_seqv2_${RUN_TAG}_nvme

echo "[driver] RUN_TAG=$RUN_TAG"
echo "[driver] node: $NODE, n_train=$N_TRAIN"
echo "[driver] shared registry: $SHARED_REGISTRY"
echo "[driver] shared cache: $SHARED_DRAM + $SHARED_NVME"

COMMON_EXPORT="ALL"
COMMON_EXPORT+=",FitCache_CROSS_JOB=1"
COMMON_EXPORT+=",FitCache_CLUSTER_REGISTRY_DIR=$SHARED_REGISTRY"
COMMON_EXPORT+=",FITPP_N_TRAIN=$N_TRAIN"
COMMON_EXPORT+=",FITPP_DROP_PAGECACHE=1"
COMMON_EXPORT+=",FitCache_DRAM_PATH=$SHARED_DRAM"
COMMON_EXPORT+=",FitCache_NVME_PATH=$SHARED_NVME"

# Job A: purges cache before starting (fresh run)
JOB_A_RESULTS=$RESULTS_DIR_BASE/jobA_${RUN_TAG}
mkdir -p "$JOB_A_RESULTS"
JOB_A_OUT=$(sbatch \
    -w "$NODE" \
    -o "$JOB_A_RESULTS/FitCachePP-%j.out" \
    --export="$COMMON_EXPORT,RESULTS_DIR=$JOB_A_RESULTS,FITPP_PURGE_CACHE=1" \
    "$REPO/benchmarks/cosmoflow/PDSW_FITPP.sh" 2>&1 | tail -1)
echo "[driver] $JOB_A_OUT (Job A on $NODE)"
JOB_A_ID=$(echo "$JOB_A_OUT" | awk '{print $NF}')

# Job B: depends on Job A; does NOT purge cache (we want Job A's cache + sidecars)
JOB_B_RESULTS=$RESULTS_DIR_BASE/jobB_${RUN_TAG}
mkdir -p "$JOB_B_RESULTS"
JOB_B_OUT=$(sbatch \
    -w "$NODE" \
    -d "afterok:$JOB_A_ID" \
    -o "$JOB_B_RESULTS/FitCachePP-%j.out" \
    --export="$COMMON_EXPORT,RESULTS_DIR=$JOB_B_RESULTS,FITPP_PURGE_CACHE=0" \
    "$REPO/benchmarks/cosmoflow/PDSW_FITPP.sh" 2>&1 | tail -1)
echo "[driver] $JOB_B_OUT (Job B on $NODE, deps:afterok:$JOB_A_ID)"
JOB_B_ID=$(echo "$JOB_B_OUT" | awk '{print $NF}')

echo
echo "[driver] Job A: SLURM $JOB_A_ID  (results: $JOB_A_RESULTS)"
echo "[driver] Job B: SLURM $JOB_B_ID  (results: $JOB_B_RESULTS, depends on A)"
echo
echo "Verification after both jobs land:"
echo "  Job A epoch-1 should be ~934s (cold cache) — same as Phase A.5"
echo "  Job B epoch-1 should be ~895s (warm via sidecar restore) — KEY headline"
echo "  grep 'restore-sidecars' $JOB_B_RESULTS/fitcache_server_log.*.0 — should show 'restored N files'"
