#!/bin/bash
# Reference FitCache_Frontier driver — runs the *original* FitCache code
# (built at /lustre/orion/gen008/proj-shared/ghu4/FitCache_Frontier/build_v2/src/)
# against the same cosmoflow workload as frontier_cosmoflow_headline.sh's
# FitCachePP side. Lets us directly A/B against the FitCachePP build.

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-1}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-2}"
GPUS_PER_NODE="${GPUS_PER_NODE:-8}"
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))
N_TRAIN="${FITPP_N_TRAIN:-8192}"
N_EPOCHS="${FITPP_N_EPOCHS:-2}"
WALLTIME="${WALLTIME:-00:30:00}"
QOS="${QOS:-hackathon}"

REF_BUILD=/lustre/orion/gen008/proj-shared/ghu4/FitCache_Frontier/build_v2/src
CLIENT_LIB="$REF_BUILD/libhvac_client.so"
SERVER_BIN="$REF_BUILD/hvac_server"

[ -f "$CLIENT_LIB" ] || { echo "ERROR: $CLIENT_LIB missing" >&2; exit 1; }
[ -x "$SERVER_BIN" ] || { echo "ERROR: $SERVER_BIN missing" >&2; exit 1; }

COSMOFLOW_DATA="${COSMOFLOW_DATA:-${FITPP_PFS_DATA_ROOT}/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2}"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_fitcache_ref
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/cosmoflow_headline/${RUN_TAG}"
mkdir -p "$ROOT_DIR/Reference"

QOS_LINE=""
[ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

cat > "$ROOT_DIR/Reference/job.sh" <<EOF
#!/bin/bash
#SBATCH -J cosmoflow_RefFitCache
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $ROOT_DIR/Reference/cosmoflow_RefFitCache-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="$ROOT_DIR/Reference"
cd "\$RESULTS_DIR"

# Reference uses HVAC_* env vars (the reference was renamed internally
# to FitCache but kept the HVAC env-var prefix).
export BBPATH=/tmp
export HVAC_DATA_DIR="$COSMOFLOW_DATA"
export HVAC_SERVER_COUNT=$TOTAL_SERVERS
export HVAC_LOG_LEVEL=600
# Reference also wants HVAC_DRAM_PATH / HVAC_NVME_PATH for data mover
export HVAC_DRAM_PATH=/tmp/fitcache_ref_dram_\$SLURM_JOB_ID
export HVAC_NVME_PATH=/tmp/fitcache_ref_nvme_\$SLURM_JOB_ID
export HVAC_DRAM_CAPACITY=\$((100 * 1024 * 1024 * 1024))
export HVAC_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))
export RDMAV_FORK_SAFE=1
mkdir -p "\$HVAC_DRAM_PATH" "\$HVAC_NVME_PATH"

# Library deps
export LD_LIBRARY_PATH=/ccs/home/ghu4/log4c-1.2.4/install/lib:/lustre/orion/gen008/proj-shared/rlibrary/mercury2.0.1/lib:\${LD_LIBRARY_PATH:-}

# Same Frontier MIOpen / TF / horovod knobs as the FitCachePP headline
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_\$SLURM_PROCID
mkdir -p \$MIOPEN_USER_DB_PATH
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3
export HOROVOD_STALL_CHECK_TIME_SECONDS=600
export HOROVOD_STALL_SHUTDOWN_TIME_SECONDS=0

echo "[Reference] nodes=\$SLURM_NNODES total_servers=\$HVAC_SERVER_COUNT gpus_per_node=$GPUS_PER_NODE"
echo "[Reference] data=\$HVAC_DATA_DIR client_lib=$CLIENT_LIB"

# Spawn servers
echo "[Reference] launching $TOTAL_SERVERS servers via srun"
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE \\
     --cpus-per-task=1 --cpu-bind=cores \\
     "$SERVER_BIN" $TOTAL_SERVERS \\
     > "\$RESULTS_DIR/hvac_server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=\$!
sleep 15

# Training wrapper
WRAPPER="\$RESULTS_DIR/train_wrapper.sh"
cat > "\$WRAPPER" <<'WEOF'
#!/bin/bash
cd \$FITPP_COSMOFLOW_DIR
LD_PRELOAD=$CLIENT_LIB \$FITPP_PYTHON_TF \\
    \$FITPP_COSMOFLOW_DIR/train.py -d \\
    --data-dir "\$HVAC_DATA_DIR" \\
    --n-train $N_TRAIN \\
    --n-epochs $N_EPOCHS
WEOF
chmod +x "\$WRAPPER"

echo "[Reference] launching training: \$((N_NODES * $GPUS_PER_NODE)) GPUs total"
START=\$SECONDS
srun -N $N_NODES -c4 --gpus-per-node=$GPUS_PER_NODE --ntasks-per-gpu=1 \\
     --cpu-bind=cores "\$WRAPPER" 2>&1 | tee "\$RESULTS_DIR/train_\${SLURM_JOB_ID}.log"
TRAIN_RC=\${PIPESTATUS[0]}
END=\$SECONDS
echo "[Reference] training wall=\$((END - START))s rc=\$TRAIN_RC"

kill -TERM \$SERVER_SRUN_PID 2>/dev/null || true
sleep 5
echo "----- Reference summary -----"
echo "  Training wall: \$((END - START))s"
EOF
chmod +x "$ROOT_DIR/Reference/job.sh"
JOB_ID=$(sbatch --parsable "$ROOT_DIR/Reference/job.sh")
echo "Reference FitCache run: $JOB_ID -> $ROOT_DIR/Reference/"
echo "Manifest will be at $ROOT_DIR"
