#!/bin/bash
#SBATCH -J cosmoflow_JobB_xjob
#SBATCH -t 00:30:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -q hackathon
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/cosmoflow_headline/20260517_164109_phase2_xjob/JobB/cosmoflow_JobB-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP

set -euo pipefail
cd $FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/cosmoflow_headline/20260517_164109_phase2_xjob/JobB"
mkdir -p "$RESULTS_DIR"
cd "$RESULTS_DIR"

# Local cache per-job-per-PID so Job-B can't see Job-A's local /tmp.
# Cross-job sharing must flow through Mercury peer_lookup, not local FS.
export BBPATH=/tmp
export FitCache_DATA_DIR="/lustre/orion/gen008/proj-shared/ghu4/data/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2"
export FitCache_DRAM_PATH=/tmp/fitcachepp_JobB_$SLURM_JOB_ID/dram
export FitCache_NVME_PATH=/tmp/fitcachepp_JobB_$SLURM_JOB_ID/nvme
export FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"
export FitCache_SERVER_COUNT=2

# THE cross-job knob. Pointed at a PFS path so both jobs find each other.
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR=/lustre/orion/gen008/proj-shared/ghu4/fitcachepp_registry/phase2_xjob/20260517_164109_phase2_xjob

mkdir -p $FitCache_DRAM_PATH $FitCache_NVME_PATH

# Frontier MIOpen / TF / horovod knobs (same as Phase 1)
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_$SLURM_PROCID
mkdir -p $MIOPEN_USER_DB_PATH
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3
export HOROVOD_STALL_CHECK_TIME_SECONDS=600
export HOROVOD_STALL_SHUTDOWN_TIME_SECONDS=0

echo "[JobB] nodes=$SLURM_NNODES servers=$FitCache_SERVER_COUNT gpus=8"
echo "[JobB] cluster_registry=$FitCache_CLUSTER_REGISTRY_DIR"
echo "[JobB] local_cache_dram=$FitCache_DRAM_PATH"

# Spawn the local FitCache servers
echo "[JobB] launching 2 servers via srun"
srun -N 1 -n 2 --ntasks-per-node=2 \
     --cpus-per-task=1 --cpu-bind=cores \
     "$FITPP_SERVER_BIN" 2 \
     > "$RESULTS_DIR/server_${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=$!
sleep 15

# Stagger Job-B so Job-A has time to warm its cache. The README rationale
# is "Job-B's local cache MUST be clean and B's cold MUST come from A's
# warm via peer_lookup" — that means B must START AFTER A has already
# cached files. The simplest version: B sleeps START_DELAY seconds before
# launching the training command. Job-A's epoch-1 wall at n=8192 is ~135s
# from Phase 1, so 180s for Job-B keeps B's epoch-1 starting AFTER A's
# epoch-1 finished — A has cached ~1024 files by then.
if [ "JobB" = "JobB" ] && [ "180" -gt 0 ]; then
    echo "[JobB] sleeping 180s so JobA has cache warmed before JobB starts"
    sleep 180
fi

WRAPPER="$RESULTS_DIR/train_wrapper.sh"
cat > "$WRAPPER" <<'WEOF'
#!/bin/bash
cd $FITPP_COSMOFLOW_DIR
LD_PRELOAD=$FITPP_CLIENT_LIB $FITPP_PYTHON_TF \
    $FITPP_COSMOFLOW_DIR/train.py -d \
    --data-dir "$FitCache_DATA_DIR" \
    --n-train 8192 \
    --n-epochs 2
WEOF
chmod +x "$WRAPPER"

echo "[JobB] launching training: 8 GPUs"
START=$SECONDS
srun -N 1 -c4 --gpus-per-node=8 --ntasks-per-gpu=1 \
     --cpu-bind=cores "$WRAPPER" 2>&1 | tee "$RESULTS_DIR/train_${SLURM_JOB_ID}.log"
TRAIN_RC=${PIPESTATUS[0]}
END=$SECONDS
echo "[JobB] training wall=$((END - START))s rc=$TRAIN_RC"

kill -TERM $SERVER_SRUN_PID 2>/dev/null || true
sleep 5

echo "----- JobB cross_job_stats (final) -----"
for f in $RESULTS_DIR/fitcache_server_log.*.0; do
    [ -f "$f" ] || continue
    echo "  $(basename $f):"
    grep 'cross_job_stats' "$f" | tail -2 | sed 's/^/    /'
done
