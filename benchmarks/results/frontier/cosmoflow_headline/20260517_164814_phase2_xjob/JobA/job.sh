#!/bin/bash
#SBATCH -J cosmoflow_JobA_xjob
#SBATCH -t 00:30:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -q hackathon
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/cosmoflow_headline/20260517_164814_phase2_xjob/JobA/cosmoflow_JobA-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP

set -euo pipefail
cd $FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/cosmoflow_headline/20260517_164814_phase2_xjob/JobA"
mkdir -p "$RESULTS_DIR"
cd "$RESULTS_DIR"

# Local cache per-job-per-PID so Job-B can't see Job-A's local /tmp.
# Cross-job sharing must flow through Mercury peer_lookup, not local FS.
export BBPATH=/tmp
export FitCache_DATA_DIR="/lustre/orion/gen008/proj-shared/ghu4/data/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2"
export FitCache_DRAM_PATH=/tmp/fitcachepp_JobA_$SLURM_JOB_ID/dram
export FitCache_NVME_PATH=/tmp/fitcachepp_JobA_$SLURM_JOB_ID/nvme
export FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"
export FitCache_SERVER_COUNT=2

# THE cross-job knob. Pointed at a PFS path so both jobs find each other.
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR=/lustre/orion/gen008/proj-shared/ghu4/fitcachepp_registry/phase2_xjob/20260517_164814_phase2_xjob
# Skip the recursive_directory_iterator manifest scan in subscribe_self_to_local_dataset.
# 524288 cosmoflow files × 8 parallel rank scans → ~9 min constructor overhead.
# Both jobs share the same root path, so root_path_hash alone matches in the
# cluster registry; manifest_hash content-divergence detection isn't load-bearing here.
export FITPP_SKIP_MANIFEST_SCAN=1

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

echo "[JobA] nodes=$SLURM_NNODES servers=$FitCache_SERVER_COUNT gpus=8"
echo "[JobA] cluster_registry=$FitCache_CLUSTER_REGISTRY_DIR"
echo "[JobA] local_cache_dram=$FitCache_DRAM_PATH"

# Spawn the local FitCache servers
echo "[JobA] launching 2 servers via srun"
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
if [ "JobA" = "JobB" ] && [ "0" -gt 0 ]; then
    echo "[JobA] sleeping 0s so JobA has cache warmed before JobB starts"
    sleep 0
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

echo "[JobA] launching training: 8 GPUs"
START=$SECONDS
srun -N 1 -c4 --gpus-per-node=8 --ntasks-per-gpu=1 \
     --cpu-bind=cores "$WRAPPER" 2>&1 | tee "$RESULTS_DIR/train_${SLURM_JOB_ID}.log"
TRAIN_RC=${PIPESTATUS[0]}
END=$SECONDS
echo "[JobA] training wall=$((END - START))s rc=$TRAIN_RC"

kill -TERM $SERVER_SRUN_PID 2>/dev/null || true
sleep 5

echo "----- JobA cross_job_stats (final) -----"
for f in $RESULTS_DIR/fitcache_server_log.*.0; do
    [ -f "$f" ] || continue
    echo "  $(basename $f):"
    grep 'cross_job_stats' "$f" | tail -2 | sed 's/^/    /'
done
