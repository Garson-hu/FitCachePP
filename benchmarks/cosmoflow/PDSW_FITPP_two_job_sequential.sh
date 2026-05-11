#!/bin/bash
#
# PDSW_FITPP_two_job_sequential.sh
#
# Two-job sequential cross-job sharing experiment. Driver script (NOT itself
# a SLURM batch script) — submits two interdependent SLURM jobs:
#
#   Job A (warmer): FitCache++ cross-job ON, runs CosmoFlow training to
#   completion on its own node (defaults to c67). Caches files in its local
#   NVMe via the data mover.
#
#   Job B (consumer): sbatched with --dependency=afterok:JOBA_ID. Same
#   FitCache_CLUSTER_REGISTRY_DIR as Job A. When B starts, A has already
#   exited, so A's servers are no longer in the live set — the registry GC
#   will eventually mark them stale, but until then they're still
#   discoverable. (For the purposes of this experiment we configure
#   FitCache_HEARTBEAT_SEC=300 so A's stale heartbeat doesn't expire while
#   B is starting up.) When B's HRW picks a slot whose addr is unreachable
#   (because A's servers exited), the open RPC fails-fast via the
#   lookup-addr signaling, and B falls back to PFS or the next HRW pick.
#   This is admittedly a stress test of the failure path more than a clean
#   cache-handoff; the cleaner test is the *concurrent* experiment in
#   PDSW_FITPP_two_job_concurrent.sh, where A is still alive when B reads.
#
# Invocation: bash PDSW_FITPP_two_job_sequential.sh
#   The driver does not itself consume a SLURM allocation; it just calls
#   sbatch twice.
#
# Default node placement: A on c67, B on c68. Override via env:
#   NODE_A=c70 NODE_B=c71 bash PDSW_FITPP_two_job_sequential.sh

set -u

NODE_A="${NODE_A:-c67}"
NODE_B="${NODE_B:-c68}"

REPO=/home/ghu4/hvac/FitCachePP
RESULTS_DIR="$REPO/benchmarks/results/two_job_sequential"
mkdir -p "$RESULTS_DIR"

# Shared cluster registry on BeeGFS (visible to both jobs).
SHARED_REGISTRY=/mnt/beegfs/ghu4/fitcachepp_registry_two_job_seq
mkdir -p "$SHARED_REGISTRY"

# Generate a per-driver-invocation registry-subdir so repeat runs of this
# script don't collide.
RUN_TAG=$(date +%Y%m%d_%H%M%S)_$$
RUN_REGISTRY="$SHARED_REGISTRY/$RUN_TAG"

# Runtime config exported into both jobs. Each job sees the same registry
# but uses its own jobid (= SLURM_JOB_ID) to scope its .ports.cfg file.
COMMON_ENV=$(cat <<EOF
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR=$RUN_REGISTRY
export FitCache_HEARTBEAT_SEC=300
export FitCache_SERVER_COUNT=4
export FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_dram_${RUN_TAG}
export FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_nvme_${RUN_TAG}
export FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((500 * 1024 * 1024 * 1024))
export FitCache_DATA_DIR=/mnt/beegfs/ghu4/hvac/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440/train/
export BBPATH=/mnt/local/ghu4/fitcachepp_nvme_${RUN_TAG}
export FitCache_LOG_LEVEL=500
export PKG_CONFIG_PATH=\$PKG_CONFIG_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/mercury-2.0.1/build/bin:\$PATH
EOF
)

# ---------- Build the per-job sbatch scripts on the fly ----------
# We need temporary sbatch files because sbatch reads its directives from a
# file. Place them under RESULTS_DIR so they're easy to find later.

JOB_A_SCRIPT="$RESULTS_DIR/${RUN_TAG}_jobA.sh"
JOB_B_SCRIPT="$RESULTS_DIR/${RUN_TAG}_jobB.sh"

cat > "$JOB_A_SCRIPT" <<EOF
#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -w $NODE_A
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_seq_A
#SBATCH -o $RESULTS_DIR/${RUN_TAG}_jobA-%j.out

$COMMON_ENV

# Use the existing single-node 4-server-per-node launcher; FitCache_CROSS_JOB
# is already exported as 1 above so it overrides the launcher's default.
exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
EOF

cat > "$JOB_B_SCRIPT" <<EOF
#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -w $NODE_B
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_seq_B
#SBATCH -o $RESULTS_DIR/${RUN_TAG}_jobB-%j.out

$COMMON_ENV

exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
EOF

chmod +x "$JOB_A_SCRIPT" "$JOB_B_SCRIPT"

# ---------- Submit ----------
echo "Submitting Job A on $NODE_A"
JOB_A_OUT=$(sbatch "$JOB_A_SCRIPT")
echo "$JOB_A_OUT"
JOB_A_ID=$(echo "$JOB_A_OUT" | awk '{print $NF}')

echo "Submitting Job B on $NODE_B (depends on Job A)"
JOB_B_OUT=$(sbatch --dependency=afterok:$JOB_A_ID "$JOB_B_SCRIPT")
echo "$JOB_B_OUT"
JOB_B_ID=$(echo "$JOB_B_OUT" | awk '{print $NF}')

echo
echo "Job A id: $JOB_A_ID  (warmer, $NODE_A)"
echo "Job B id: $JOB_B_ID  (consumer, $NODE_B; --dependency=afterok:$JOB_A_ID)"
echo "Shared registry: $RUN_REGISTRY"
echo "Logs: $RESULTS_DIR/${RUN_TAG}_jobA-${JOB_A_ID}.out + ${RUN_TAG}_jobB-${JOB_B_ID}.out"
echo
echo "When both jobs complete, grep job B's logs for 'peer_lookup' / 'redirect'"
echo "  to confirm Job B routed any reads to Job A's cached files."
