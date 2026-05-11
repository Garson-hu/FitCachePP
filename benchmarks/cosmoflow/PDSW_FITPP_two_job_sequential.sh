#!/bin/bash
#
# PDSW_FITPP_two_job_sequential.sh
#
# Two-job sequential cross-job sharing experiment. Driver script: submits
# two SLURM jobs both pinned to the SAME node, with Job B waiting on
# Job A via --dependency=afterok. Both jobs share:
#   - the same FitCache_CLUSTER_REGISTRY_DIR (on BeeGFS)
#   - the same node-local cache paths (FitCache_DRAM_PATH / FitCache_NVME_PATH)
#
# Sequence:
#   1. Job A starts on node N. Cluster-registry has only A's servers.
#      Cross-job is on; A's data mover writes both the cached file and a
#      sidecar (.meta) for every promotion.
#   2. Job A's training completes; A's servers exit; A's registry entries
#      are deregistered (unlink of <hostname>_rank<n>.txt).
#   3. SLURM frees N's allocation, lets Job B start (it was waiting on
#      --dependency=afterok:JOB_A).
#   4. Job B starts on node N. Job B's fitcache_server processes scan
#      FitCache_DRAM_PATH + FitCache_NVME_PATH at startup
#      (registry init + fitcache_data_mover_restore_from_sidecars), find
#      the sidecars Job A left behind, and rebuild path_cache_map +
#      g_dram_used_bytes / g_nvme_used_bytes from disk.
#   5. Job B runs the same training. Its first epoch should hit warm cache
#      everywhere (Job A populated it). This is the COLD-START ELIMINATION
#      claim: Job B's epoch-1 should match Job A's warm-epoch time, not
#      Job A's cold-epoch time.
#
# This is the test that exercises the persistent-sidecar-metadata pathway
# end-to-end across job boundaries. The localhost smoke can't easily
# exercise it because both ends of a localhost smoke share the lifetime of
# the harness script.
#
# Invocation: bash PDSW_FITPP_two_job_sequential.sh
#   The driver does NOT consume a SLURM allocation; it just calls sbatch
#   twice (with --dependency on the second).
#
# Default node: c66. Override via env: NODE=c67 bash PDSW_FITPP_two_job_sequential.sh

set -u

NODE="${NODE:-c66}"

REPO=/home/ghu4/hvac/FitCachePP
RESULTS_DIR="$REPO/benchmarks/results/two_job_sequential"
mkdir -p "$RESULTS_DIR"

SHARED_REGISTRY=/mnt/beegfs/ghu4/fitcachepp_registry_two_job_sequential
mkdir -p "$SHARED_REGISTRY"

RUN_TAG=$(date +%Y%m%d_%H%M%S)_$$
RUN_REGISTRY="$SHARED_REGISTRY/$RUN_TAG"

# Both jobs share the same DRAM/NVME paths (same node) — that's how Job B
# discovers Job A's cached files. RUN_TAG keeps repeat runs of this driver
# from interfering with each other.
COMMON_ENV=$(cat <<EOF
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR=$RUN_REGISTRY
export FitCache_HEARTBEAT_SEC=10
export FitCache_SERVER_COUNT=4
export SERVERS_PER_NODE=4
export FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_dram_seq_${RUN_TAG}
export FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_nvme_seq_${RUN_TAG}
export FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((500 * 1024 * 1024 * 1024))
# NOTE: parent of train/ + validation/, so the LD_PRELOAD substring filter
# (fitcache_client.cpp:116) catches both. train.py gets the same path via
# --data-dir in command_CF_FITPP.sh.
export FitCache_DATA_DIR=/mnt/beegfs/ghu4/hvac/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440
export BBPATH=/mnt/local/ghu4/fitcachepp_nvme_seq_${RUN_TAG}
export FitCache_LOG_LEVEL=500
export PKG_CONFIG_PATH=\$PKG_CONFIG_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/rlibrary/miniconda3/envs/hvac_tf/bin:/home/ghu4/hvac/mercury-2.0.1/build/bin:\$PATH
export RESULTS_DIR=$RESULTS_DIR
EOF
)

JOB_A_SCRIPT="$RESULTS_DIR/${RUN_TAG}_jobA.sh"
JOB_B_SCRIPT="$RESULTS_DIR/${RUN_TAG}_jobB.sh"

cat > "$JOB_A_SCRIPT" <<EOF
#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -w $NODE
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_seq_A
#SBATCH -o $RESULTS_DIR/${RUN_TAG}_jobA-%j.out

$COMMON_ENV
exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
EOF

cat > "$JOB_B_SCRIPT" <<EOF
#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -w $NODE
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_seq_B
#SBATCH -o $RESULTS_DIR/${RUN_TAG}_jobB-%j.out

$COMMON_ENV
exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
EOF

chmod +x "$JOB_A_SCRIPT" "$JOB_B_SCRIPT"

echo "Submitting Job A on $NODE (warmer)"
JOB_A_OUT=$(sbatch "$JOB_A_SCRIPT")
echo "$JOB_A_OUT"
JOB_A_ID=$(echo "$JOB_A_OUT" | awk '{print $NF}')

echo "Submitting Job B on $NODE (consumer; --dependency=afterok:$JOB_A_ID)"
JOB_B_OUT=$(sbatch --dependency=afterok:$JOB_A_ID "$JOB_B_SCRIPT")
echo "$JOB_B_OUT"
JOB_B_ID=$(echo "$JOB_B_OUT" | awk '{print $NF}')

echo
echo "Job A id: $JOB_A_ID  (warmer, $NODE)"
echo "Job B id: $JOB_B_ID  (consumer, $NODE; --dependency=afterok:$JOB_A_ID)"
echo "Shared cache:    /mnt/local/ghu4/fitcachepp_{dram,nvme}_seq_${RUN_TAG} on $NODE"
echo "Shared registry: $RUN_REGISTRY"
echo
echo "Expected: Job A epoch-1 cold ~362s; Job B epoch-1 should be warm-cache (~190s)"
echo "  thanks to the sidecar scan at server startup rebuilding path_cache_map"
echo "  from the .meta files Job A left behind on the local NVMe."
