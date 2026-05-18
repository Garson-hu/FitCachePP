#!/bin/bash
#SBATCH -J cosmoflow_FitCachePP
#SBATCH -t 00:45:00
#SBATCH -N 16
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -q hackathon
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/cosmoflow_headline/20260517_234657_cosmoflow_headline/FitCachePP/cosmoflow_FitCachePP-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP

set -euo pipefail
cd $FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/cosmoflow_headline/20260517_234657_cosmoflow_headline/FitCachePP"
mkdir -p "$RESULTS_DIR"
cd "$RESULTS_DIR"

# FitCache env. BBPATH=/tmp per the user's known-working HVAC pattern
# (cf. [[feedback-frontier-multi-gpu-pattern]]); we keep the cache dirs
# under /tmp too rather than /mnt/bb/ghu4 to match.
export BBPATH=/tmp
export FitCache_DATA_DIR="/lustre/orion/gen008/proj-shared/ghu4/data/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2"
export FitCache_DRAM_PATH=/tmp/fitcachepp_FitCachePP_20260517_234657_cosmoflow_headline_dram
export FitCache_NVME_PATH=/tmp/fitcachepp_FitCachePP_20260517_234657_cosmoflow_headline_nvme
export FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))    # 100 GiB
export FitCache_NVME_CAPACITY=$((1500 * 1024 * 1024 * 1024))   # 1.5 TiB  (fits 1.4 TB v2 set)
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"
export FitCache_SERVER_COUNT=64
export FitCache_CROSS_JOB=0
# Profiling: emit FitCache_TIMING per-tag histogram on client exit. Lets us
# compare single-job ms_read.hrw_normal_total latency against cross-job
# peer_redirect_total to quantify Mercury overhead.
export FITPP_TIMING_DUMP_ON_EXIT=1

# MIOpen knobs (mandatory on Frontier — SQLite kernel cache breaks on NFS $HOME)
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_$SLURM_PROCID
mkdir -p $MIOPEN_USER_DB_PATH

# Horovod stall-check tolerance: the FitCachePP LD_PRELOAD client serialises
# open RPCs through 2 fitcache_servers per node, so the slowest rank's
# data-pipeline prefetch can lag the fastest rank's by tens of seconds —
# Horovod's default 60s stall_check fires before slow ranks catch up. Raise
# to 600s so training proceeds (with the expected per-iter slowdown) rather
# than aborting. Set HOROVOD_STALL_CHECK_DISABLE=1 to suppress the warning
# spew entirely; we keep it on so a TRUE deadlock (no progress at all) is
# still visible.
export HOROVOD_STALL_CHECK_TIME_SECONDS=600
export HOROVOD_STALL_SHUTDOWN_TIME_SECONDS=0  # 0 = warn only, never abort
# Cycle time controls how often Horovod polls the request queue. Default 5ms
# is fine; explicit so future debug knows where the knob is.
export HOROVOD_CYCLE_TIME=5

# TF / XLA / ROCm bitcode mismatch workarounds (see commit history)
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3

mkdir -p "$FitCache_DRAM_PATH" "$FitCache_NVME_PATH"

echo "[FitCachePP] nodes=$SLURM_NNODES  total_servers=$FitCache_SERVER_COUNT  gpus_per_node=8"
echo "[FitCachePP] data=$FitCache_DATA_DIR"

# ---- spawn FitCachePP servers (always, even on Pure_CF; Pure_CF just doesn't LD_PRELOAD)
echo "[FitCachePP] launching 64 servers via srun"
srun -N 16 -n 64 --ntasks-per-node=4 \
     --cpus-per-task=1 --cpu-bind=cores \
     "$FITPP_SERVER_BIN" 64 \
     > "$RESULTS_DIR/server_${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=$!
sleep 15

# ---- training command (one srun, one task per GPU)
# Wrapper that each srun task runs: sets LD_PRELOAD (for FitCachePP)
# then invokes python train.py. horovod.init() inside the python picks
# up rank/size from the SLURM/PMI env.
WRAPPER="$RESULTS_DIR/train_wrapper.sh"
cat > "$WRAPPER" <<'WEOF'
#!/bin/bash
cd $FITPP_COSMOFLOW_DIR
LD_PRELOAD="$FITPP_CLIENT_LIB" $FITPP_PYTHON_TF \
    $FITPP_COSMOFLOW_DIR/train.py -d \
    --data-dir "$FitCache_DATA_DIR" \
    --n-train 131072 \
    --n-valid 1024 \
    --n-epochs 2
WEOF
chmod +x "$WRAPPER"

echo "[FitCachePP] launching training: 128 GPUs total"
START=$SECONDS
srun -N 16 -c4 --gpus-per-node=8 --ntasks-per-gpu=1 \
     --cpu-bind=cores "$WRAPPER" 2>&1 | tee "$RESULTS_DIR/train_${SLURM_JOB_ID}.log"
TRAIN_RC=${PIPESTATUS[0]}
END=$SECONDS
echo "[FitCachePP] training wall=$((END - START))s rc=$TRAIN_RC"

# ---- teardown
echo "[FitCachePP] tearing down servers"
kill -TERM $SERVER_SRUN_PID 2>/dev/null || true
sleep 5

OPEN_RPC=$(grep -cE "Open RPC: requested path" $RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
MMAP=$(grep -cE "mmap on tracked fd|mmap: redirected to anon" $RESULTS_DIR/fitcache_intercept_log.*.0 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
EPOCH_LINES=$(grep -cE "time:.*[0-9]+s/epoch" $RESULTS_DIR/train_${SLURM_JOB_ID}.log 2>/dev/null || echo 0)
echo "----- FitCachePP summary -----"
echo "  Training wall:    $((END - START))s"
echo "  Open RPCs:        $OPEN_RPC"
echo "  mmap-redirects:   $MMAP"
echo "  epochs completed: $EPOCH_LINES"
