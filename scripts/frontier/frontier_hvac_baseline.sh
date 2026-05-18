#!/bin/bash
# HVAC reference baseline driver — cosmoflow at the same scale as
# frontier_cosmoflow_headline.sh's FitCachePP run, but using the
# upstream HVAC implementation from /ccs/home/ghu4/new_hvac_copy
# (built into /ccs/home/ghu4/new_hvac_copy/build_frontier/src/).
#
# Purpose: confirm on Frontier that HVAC's cold-epoch wall ≈ Pure_CF's
# cold-epoch wall at n_train=32768 / 1 node / 8 GPUs (which the user
# reports is the expected behaviour). Once confirmed, this gives us a
# concrete number to diff FitCachePP against.

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-1}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-2}"
GPUS_PER_NODE="${GPUS_PER_NODE:-8}"
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))
N_TRAIN="${FITPP_N_TRAIN:-32768}"
N_EPOCHS="${FITPP_N_EPOCHS:-2}"
WALLTIME="${WALLTIME:-01:55:00}"
QOS="${QOS:-debug}"

HVAC_BUILD_DIR=/ccs/home/ghu4/new_hvac_copy/build_frontier/src
HVAC_CLIENT_LIB="$HVAC_BUILD_DIR/libhvac_client.so"
HVAC_SERVER_BIN="$HVAC_BUILD_DIR/hvac_server"

if [ ! -f "$HVAC_CLIENT_LIB" ] || [ ! -x "$HVAC_SERVER_BIN" ]; then
    echo "ERROR: HVAC build artifacts not at $HVAC_BUILD_DIR" >&2
    exit 1
fi

COSMOFLOW_DATA="${COSMOFLOW_DATA:-${FITPP_PFS_DATA_ROOT}/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2}"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_hvac_baseline
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/cosmoflow_headline/${RUN_TAG}"
mkdir -p "$ROOT_DIR/HVAC"

QOS_LINE=""
if [ -n "$QOS" ]; then
    QOS_LINE="#SBATCH -q $QOS"
fi

cat > "$ROOT_DIR/HVAC/job.sh" <<EOF
#!/bin/bash
#SBATCH -J cosmoflow_HVAC
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $ROOT_DIR/HVAC/cosmoflow_HVAC-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="$ROOT_DIR/HVAC"
mkdir -p "\$RESULTS_DIR"
cd "\$RESULTS_DIR"

# HVAC env (per /ccs/home/ghu4/new_hvac_copy/build/build_frontier.sh)
export BBPATH=/tmp
export HVAC_DATA_DIR="$COSMOFLOW_DATA"
export HVAC_SERVER_COUNT=$TOTAL_SERVERS
export HVAC_LOG_LEVEL=600
export RDMAV_FORK_SAFE=1
mkdir -p \$BBPATH

# Add our log4c + Mercury library paths so HVAC's .so finds its deps
export LD_LIBRARY_PATH=/ccs/home/ghu4/log4c-1.2.4/install/lib:/lustre/orion/gen008/proj-shared/rlibrary/mercury2.0.1/lib:\${LD_LIBRARY_PATH:-}

# Frontier MIOpen / TF / XLA knobs (same as the FitCachePP headline)
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_\$SLURM_PROCID
mkdir -p \$MIOPEN_USER_DB_PATH
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3

# Same horovod tolerance knob we tuned during FitCachePP debug
export HOROVOD_STALL_CHECK_TIME_SECONDS=600
export HOROVOD_STALL_SHUTDOWN_TIME_SECONDS=0

echo "[HVAC] nodes=\$SLURM_NNODES total_servers=\$HVAC_SERVER_COUNT gpus_per_node=$GPUS_PER_NODE"
echo "[HVAC] data=\$HVAC_DATA_DIR  hvac_client_lib=$HVAC_CLIENT_LIB"

# ---- spawn HVAC servers
echo "[HVAC] launching $TOTAL_SERVERS servers via srun"
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE \\
     --cpus-per-task=1 --cpu-bind=cores \\
     "$HVAC_SERVER_BIN" $TOTAL_SERVERS \\
     > "\$RESULTS_DIR/hvac_server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=\$!
sleep 15

# ---- training wrapper
WRAPPER="\$RESULTS_DIR/train_wrapper.sh"
cat > "\$WRAPPER" <<'WEOF'
#!/bin/bash
cd \$FITPP_COSMOFLOW_DIR
LD_PRELOAD=$HVAC_CLIENT_LIB \$FITPP_PYTHON_TF \\
    \$FITPP_COSMOFLOW_DIR/train.py -d \\
    --data-dir "\$HVAC_DATA_DIR" \\
    --n-train $N_TRAIN \\
    --n-epochs $N_EPOCHS
WEOF
chmod +x "\$WRAPPER"

echo "[HVAC] launching training: \$((N_NODES * $GPUS_PER_NODE)) GPUs total"
START=\$SECONDS
srun -N $N_NODES -c4 --gpus-per-node=$GPUS_PER_NODE --ntasks-per-gpu=1 \\
     --cpu-bind=cores "\$WRAPPER" 2>&1 | tee "\$RESULTS_DIR/train_\${SLURM_JOB_ID}.log"
TRAIN_RC=\${PIPESTATUS[0]}
END=\$SECONDS
echo "[HVAC] training wall=\$((END - START))s rc=\$TRAIN_RC"

# Teardown
kill -TERM \$SERVER_SRUN_PID 2>/dev/null || true
sleep 5

echo "----- HVAC summary -----"
echo "  Training wall: \$((END - START))s"
EOF
chmod +x "$ROOT_DIR/HVAC/job.sh"
JOB_ID=$(sbatch --parsable "$ROOT_DIR/HVAC/job.sh")
echo "HVAC reference run: $JOB_ID  -> $ROOT_DIR/HVAC/"
cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
job_hvac=$JOB_ID
qos=$QOS
n_nodes=$N_NODES
gpus_per_node=$GPUS_PER_NODE
servers_per_node=$SERVERS_PER_NODE
total_servers=$TOTAL_SERVERS
n_train=$N_TRAIN
n_epochs=$N_EPOCHS
data_dir=$COSMOFLOW_DATA
walltime=$WALLTIME
hvac_client_lib=$HVAC_CLIENT_LIB
hvac_server_bin=$HVAC_SERVER_BIN
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
