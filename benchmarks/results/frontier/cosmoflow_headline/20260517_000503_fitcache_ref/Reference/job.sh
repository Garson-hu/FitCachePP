#!/bin/bash
#SBATCH -J cosmoflow_RefFitCache
#SBATCH -t 00:30:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -q hackathon
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/cosmoflow_headline/20260517_000503_fitcache_ref/Reference/cosmoflow_RefFitCache-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP

set -euo pipefail
cd $FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/cosmoflow_headline/20260517_000503_fitcache_ref/Reference"
cd "$RESULTS_DIR"

# Reference uses HVAC_* env vars (the reference was renamed internally
# to FitCache but kept the HVAC env-var prefix).
export BBPATH=/tmp
export HVAC_DATA_DIR="/lustre/orion/gen008/proj-shared/ghu4/data/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2"
export HVAC_SERVER_COUNT=1
export HVAC_LOG_LEVEL=600
# Reference also wants HVAC_DRAM_PATH / HVAC_NVME_PATH for data mover
export HVAC_DRAM_PATH=/tmp/fitcache_ref_dram_$SLURM_JOB_ID
export HVAC_NVME_PATH=/tmp/fitcache_ref_nvme_$SLURM_JOB_ID
export HVAC_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))
export HVAC_NVME_CAPACITY=$((1500 * 1024 * 1024 * 1024))
export RDMAV_FORK_SAFE=1
mkdir -p "$HVAC_DRAM_PATH" "$HVAC_NVME_PATH"

# Library deps
export LD_LIBRARY_PATH=/ccs/home/ghu4/log4c-1.2.4/install/lib:/lustre/orion/gen008/proj-shared/rlibrary/mercury2.0.1/lib:${LD_LIBRARY_PATH:-}

# Same Frontier MIOpen / TF / horovod knobs as the FitCachePP headline
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_$SLURM_PROCID
mkdir -p $MIOPEN_USER_DB_PATH
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3
export HOROVOD_STALL_CHECK_TIME_SECONDS=600
export HOROVOD_STALL_SHUTDOWN_TIME_SECONDS=0

echo "[Reference] nodes=$SLURM_NNODES total_servers=$HVAC_SERVER_COUNT gpus_per_node=1"
echo "[Reference] data=$HVAC_DATA_DIR client_lib=/lustre/orion/gen008/proj-shared/ghu4/FitCache_Frontier/build_v2/src/libhvac_client.so"

# Spawn servers
echo "[Reference] launching 1 servers via srun"
srun -N 1 -n 1 --ntasks-per-node=1 \
     --cpus-per-task=1 --cpu-bind=cores \
     "/lustre/orion/gen008/proj-shared/ghu4/FitCache_Frontier/build_v2/src/hvac_server" 1 \
     > "$RESULTS_DIR/hvac_server_${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=$!
sleep 15

# Training wrapper
WRAPPER="$RESULTS_DIR/train_wrapper.sh"
cat > "$WRAPPER" <<'WEOF'
#!/bin/bash
cd $FITPP_COSMOFLOW_DIR
LD_PRELOAD=/lustre/orion/gen008/proj-shared/ghu4/FitCache_Frontier/build_v2/src/libhvac_client.so $FITPP_PYTHON_TF \
    $FITPP_COSMOFLOW_DIR/train.py -d \
    --data-dir "$HVAC_DATA_DIR" \
    --n-train 1024 \
    --n-epochs 2
WEOF
chmod +x "$WRAPPER"

echo "[Reference] launching training: $((N_NODES * 1)) GPUs total"
START=$SECONDS
srun -N 1 -c4 --gpus-per-node=1 --ntasks-per-gpu=1 \
     --cpu-bind=cores "$WRAPPER" 2>&1 | tee "$RESULTS_DIR/train_${SLURM_JOB_ID}.log"
TRAIN_RC=${PIPESTATUS[0]}
END=$SECONDS
echo "[Reference] training wall=$((END - START))s rc=$TRAIN_RC"

kill -TERM $SERVER_SRUN_PID 2>/dev/null || true
sleep 5
echo "----- Reference summary -----"
echo "  Training wall: $((END - START))s"
