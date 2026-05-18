#!/bin/bash
#SBATCH -J cosmoflow_HVAC
#SBATCH -t 00:30:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -q hackathon
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/cosmoflow_headline/20260516_122745_hvac_baseline/HVAC/cosmoflow_HVAC-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP

set -euo pipefail
cd $FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/cosmoflow_headline/20260516_122745_hvac_baseline/HVAC"
mkdir -p "$RESULTS_DIR"
cd "$RESULTS_DIR"

# HVAC env (per /ccs/home/ghu4/new_hvac_copy/build/build_frontier.sh)
export BBPATH=/tmp
export HVAC_DATA_DIR="/lustre/orion/gen008/proj-shared/ghu4/data/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2"
export HVAC_SERVER_COUNT=2
export HVAC_LOG_LEVEL=600
export RDMAV_FORK_SAFE=1
mkdir -p $BBPATH

# Add our log4c + Mercury library paths so HVAC's .so finds its deps
export LD_LIBRARY_PATH=/ccs/home/ghu4/log4c-1.2.4/install/lib:/lustre/orion/gen008/proj-shared/rlibrary/mercury2.0.1/lib:${LD_LIBRARY_PATH:-}

# Frontier MIOpen / TF / XLA knobs (same as the FitCachePP headline)
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_$SLURM_PROCID
mkdir -p $MIOPEN_USER_DB_PATH
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3

# Same horovod tolerance knob we tuned during FitCachePP debug
export HOROVOD_STALL_CHECK_TIME_SECONDS=600
export HOROVOD_STALL_SHUTDOWN_TIME_SECONDS=0

echo "[HVAC] nodes=$SLURM_NNODES total_servers=$HVAC_SERVER_COUNT gpus_per_node=8"
echo "[HVAC] data=$HVAC_DATA_DIR  hvac_client_lib=/ccs/home/ghu4/new_hvac_copy/build_frontier/src/libhvac_client.so"

# ---- spawn HVAC servers
echo "[HVAC] launching 2 servers via srun"
srun -N 1 -n 2 --ntasks-per-node=2 \
     --cpus-per-task=1 --cpu-bind=cores \
     "/ccs/home/ghu4/new_hvac_copy/build_frontier/src/hvac_server" 2 \
     > "$RESULTS_DIR/hvac_server_${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=$!
sleep 15

# ---- training wrapper
WRAPPER="$RESULTS_DIR/train_wrapper.sh"
cat > "$WRAPPER" <<'WEOF'
#!/bin/bash
cd $FITPP_COSMOFLOW_DIR
LD_PRELOAD=/ccs/home/ghu4/new_hvac_copy/build_frontier/src/libhvac_client.so $FITPP_PYTHON_TF \
    $FITPP_COSMOFLOW_DIR/train.py -d \
    --data-dir "$HVAC_DATA_DIR" \
    --n-train 32768 \
    --n-epochs 2
WEOF
chmod +x "$WRAPPER"

echo "[HVAC] launching training: $((N_NODES * 8)) GPUs total"
START=$SECONDS
srun -N 1 -c4 --gpus-per-node=8 --ntasks-per-gpu=1 \
     --cpu-bind=cores "$WRAPPER" 2>&1 | tee "$RESULTS_DIR/train_${SLURM_JOB_ID}.log"
TRAIN_RC=${PIPESTATUS[0]}
END=$SECONDS
echo "[HVAC] training wall=$((END - START))s rc=$TRAIN_RC"

# Teardown
kill -TERM $SERVER_SRUN_PID 2>/dev/null || true
sleep 5

echo "----- HVAC summary -----"
echo "  Training wall: $((END - START))s"
