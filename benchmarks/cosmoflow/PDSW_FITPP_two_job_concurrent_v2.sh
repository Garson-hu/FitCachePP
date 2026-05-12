#!/usr/bin/env bash
#
# PDSW_FITPP_two_job_concurrent_v2.sh
#
# Phase B.1 driver: submit two FitCachePP single-node jobs concurrently
# on different GPU nodes, both pointing at the same FitCache_CLUSTER_REGISTRY_DIR
# so they exercise the cross-job sharing pathway (peer_lookup + redirect).
#
# Each sub-job is a normal PDSW_FITPP.sh run with these per-job overrides:
#   - FitCache_CROSS_JOB=1
#   - FitCache_CLUSTER_REGISTRY_DIR=<shared>/<RUN_TAG>
#   - FitCache_DRAM_PATH/_NVME_PATH = unique per-node /mnt/local subdirs
#     (each GPU node has its own /mnt/local, so no on-disk collision)
#   - FITPP_DROP_PAGECACHE=1 to evict OS page cache before training
#   - FITPP_PURGE_CACHE=1 to wipe local FitCache cache between runs
#
# Submission: the driver runs from a login node (NOT inside an sbatch).
# It just calls sbatch twice with different --export env vars.
#
# Defaults:
#   NODE_A=c66 (GPU client + 4 servers)
#   NODE_B=c67 (GPU client + 4 servers)
#   n_train=8192
# Override via env: NODE_A=c54 NODE_B=c55 bash PDSW_FITPP_two_job_concurrent_v2.sh

set -u
set -o pipefail

NODE_A="${NODE_A:-c66}"
NODE_B="${NODE_B:-c67}"
N_TRAIN="${FITPP_N_TRAIN:-8192}"

REPO=/home/ghu4/hvac/FitCachePP
RESULTS_DIR_BASE="$REPO/benchmarks/results/two_job_concurrent_v2"
mkdir -p "$RESULTS_DIR_BASE"

RUN_TAG=$(date +%Y%m%d_%H%M%S)_$$
SHARED_REGISTRY=/mnt/beegfs/ghu4/fitcachepp_registry_two_job_concurrent_v2/$RUN_TAG
mkdir -p "$SHARED_REGISTRY"

echo "[driver] RUN_TAG=$RUN_TAG"
echo "[driver] shared registry: $SHARED_REGISTRY"
echo "[driver] Job A on $NODE_A, Job B on $NODE_B, n_train=$N_TRAIN"

# Common env both sub-jobs need.
COMMON_EXPORT="ALL"
COMMON_EXPORT+=",FitCache_CROSS_JOB=1"
COMMON_EXPORT+=",FitCache_CLUSTER_REGISTRY_DIR=$SHARED_REGISTRY"
COMMON_EXPORT+=",FITPP_N_TRAIN=$N_TRAIN"
COMMON_EXPORT+=",FITPP_DROP_PAGECACHE=1"
COMMON_EXPORT+=",FITPP_PURGE_CACHE=1"

# Submit Job A with FITPP_SEED=1 + Job B with FITPP_SEED=2 so the two jobs
# shuffle the dataset DIFFERENTLY. With identical seeds (the prior default
# of --seed=0 in both jobs), both jobs read files in the same order and
# race at every open — peer_lookup always sees an empty cache because the
# file hasn't been promoted on either side yet. Different seeds let one
# job get ahead on a given file → peer_lookup finds HAS=1 → cross-job
# sharing actually fires.
JOB_A_RESULTS=$RESULTS_DIR_BASE/jobA_${RUN_TAG}
mkdir -p "$JOB_A_RESULTS"
JOB_A_OUT=$(sbatch \
    -w "$NODE_A" \
    -o "$JOB_A_RESULTS/FitCachePP-%j.out" \
    --export="$COMMON_EXPORT,FITPP_SEED=1,RESULTS_DIR=$JOB_A_RESULTS,FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_concv2_${RUN_TAG}_dram,FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_concv2_${RUN_TAG}_nvme" \
    "$REPO/benchmarks/cosmoflow/PDSW_FITPP.sh" 2>&1 | tail -1)
echo "[driver] $JOB_A_OUT (Job A on $NODE_A, seed=1)"

JOB_B_RESULTS=$RESULTS_DIR_BASE/jobB_${RUN_TAG}
mkdir -p "$JOB_B_RESULTS"
JOB_B_OUT=$(sbatch \
    -w "$NODE_B" \
    -o "$JOB_B_RESULTS/FitCachePP-%j.out" \
    --export="$COMMON_EXPORT,FITPP_SEED=2,RESULTS_DIR=$JOB_B_RESULTS,FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_concv2_${RUN_TAG}_dram,FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_concv2_${RUN_TAG}_nvme" \
    "$REPO/benchmarks/cosmoflow/PDSW_FITPP.sh" 2>&1 | tail -1)
echo "[driver] $JOB_B_OUT (Job B on $NODE_B, seed=2)"

JOB_A_ID=$(echo "$JOB_A_OUT" | awk '{print $NF}')
JOB_B_ID=$(echo "$JOB_B_OUT" | awk '{print $NF}')

echo
echo "[driver] Job A: SLURM $JOB_A_ID  (results: $JOB_A_RESULTS)"
echo "[driver] Job B: SLURM $JOB_B_ID  (results: $JOB_B_RESULTS)"
echo "[driver] shared registry: $SHARED_REGISTRY"
echo
echo "Verification after both jobs land:"
echo "  grep -h 'cross_job_stats' $JOB_A_RESULTS/fitcache_server_log.*.0 | tail -3"
echo "  grep -h 'cross_job_stats' $JOB_B_RESULTS/fitcache_server_log.*.0 | tail -3"
echo "Expected: at least one job has peer_lookup_forwarded > 0 AND opens_redirect_to_peer > 0"
