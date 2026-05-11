#!/bin/bash
#
# PDSW_FITPP_two_job_concurrent.sh
#
# Two-job concurrent cross-job sharing experiment. Driver script: submits
# TWO independent SLURM jobs at the same time, on different nodes,
# pointing at the same FitCache_CLUSTER_REGISTRY_DIR. Whichever job
# warms a file first, the other should hit the warmed cache via the
# cross-job peer-lookup + redirect path.
#
# The cross-job-sharing-reduces-aggregate-IO claim is the headline
# experiment defended here: total wall-clock for two concurrent jobs
# should be lower than 2 x single-job, because the second job to read
# any given file gets a peer-cache hit instead of a PFS read.
#
# Invocation: bash PDSW_FITPP_two_job_concurrent.sh
#   The driver does not consume a SLURM allocation; it just calls sbatch
#   twice (no --dependency, both run in parallel).
#
# Default node placement: A on c70, B on c71. Override via env:
#   NODE_A=c66 NODE_B=c67 bash PDSW_FITPP_two_job_concurrent.sh

set -u

NODE_A="${NODE_A:-c70}"
NODE_B="${NODE_B:-c71}"

REPO=/home/ghu4/hvac/FitCachePP
RESULTS_DIR="$REPO/benchmarks/results/two_job_concurrent"
mkdir -p "$RESULTS_DIR"

# Shared cluster registry on BeeGFS.
SHARED_REGISTRY=/mnt/beegfs/ghu4/fitcachepp_registry_two_job_concurrent
mkdir -p "$SHARED_REGISTRY"

RUN_TAG=$(date +%Y%m%d_%H%M%S)_$$
RUN_REGISTRY="$SHARED_REGISTRY/$RUN_TAG"

# Each job uses its OWN local cache path (since they're on different nodes,
# the local /mnt/local doesn't conflict, but we tag with RUN_TAG so repeat
# runs don't reuse a stale cache).
COMMON_ENV=$(cat <<EOF
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR=$RUN_REGISTRY
export FitCache_HEARTBEAT_SEC=10
export FitCache_SERVER_COUNT=4
export SERVERS_PER_NODE=4
export FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_dram_${RUN_TAG}
export FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_nvme_${RUN_TAG}
export FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((500 * 1024 * 1024 * 1024))
# NOTE: parent of train/ + validation/, so the LD_PRELOAD substring filter
# (fitcache_client.cpp:116) catches both. train.py gets the same path via
# --data-dir in command_CF_FITPP.sh.
export FitCache_DATA_DIR=/mnt/beegfs/ghu4/hvac/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440
export BBPATH=/mnt/local/ghu4/fitcachepp_nvme_${RUN_TAG}
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
#SBATCH -w $NODE_A
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_con_A
#SBATCH -o $RESULTS_DIR/${RUN_TAG}_jobA-%j.out

$COMMON_ENV
exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
EOF

cat > "$JOB_B_SCRIPT" <<EOF
#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -w $NODE_B
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_con_B
#SBATCH -o $RESULTS_DIR/${RUN_TAG}_jobB-%j.out

$COMMON_ENV
exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
EOF

chmod +x "$JOB_A_SCRIPT" "$JOB_B_SCRIPT"

echo "Submitting Job A on $NODE_A and Job B on $NODE_B (parallel)"
JOB_A_ID=$(sbatch "$JOB_A_SCRIPT" | awk '{print $NF}')
JOB_B_ID=$(sbatch "$JOB_B_SCRIPT" | awk '{print $NF}')
echo "Job A id: $JOB_A_ID  ($NODE_A)"
echo "Job B id: $JOB_B_ID  ($NODE_B)"
echo "Shared registry: $RUN_REGISTRY"
echo
echo "When both finish, grep BOTH jobs' server logs for 'peer_lookup' / 'HAS' / 'redirect'"
echo "  to count cross-job hits in either direction. Total wall-clock from"
echo "  sacct on the two job IDs is the headline metric (lower = sharing helped)."
