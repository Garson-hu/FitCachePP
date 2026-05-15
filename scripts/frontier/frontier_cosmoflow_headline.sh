#!/bin/bash
# Frontier CosmoFlow headline FitCachePP-vs-Pure_CF comparison.
#
# The full-dataset (n_train=524288 = 2^19, the canonical
# cosmoUniverse_2019_05_4parE_tf_v2) measurement is the load-bearing
# evidence for the per-job-speedup claim. It needs full MI250X
# utilization — one rank per GCD, 8 ranks per node — to land in
# tractable wall-clock; single-GPU at this scale would take ~50 h.
#
# Launch pattern (per the user's known-working HVAC sbatch script
# saved as [[feedback-frontier-multi-gpu-pattern]]):
#   1. Module-load rocm/6.0.0 + python/3.10-miniforge3 + gcc/12.2.0
#      (NOT gcc-native/13).
#   2. MIOpen env: DISABLE_CACHE=1, FIND_MODE=3,
#      USER_DB_PATH=/tmp/miopen_cache_$SLURM_PROCID.
#   3. Spawn FitCachePP servers via `srun -N N --ntasks-per-node=K
#      --cpus-per-task=1 --cpu-bind=cores fitcache_server $TOTAL &`
#      and rendezvous via /tmp/fitcache_server.pid (if available) or
#      a fixed sleep.
#   4. Run training via `srun -N N --gpus-per-node=8 --ntasks-per-gpu=1
#      --cpu-bind=cores wrapper.sh`. The wrapper just sets LD_PRELOAD
#      and invokes python train.py; each srun task is a separate
#      process, and horovod.init() inside the python picks up rank /
#      size from the SLURM/PMI env. NO horovodrun.
#
# Submits TWO sbatches (FitCachePP + Pure_CF) so each side runs on
# a fresh node (no warm-cache leakage between sides).
#
# Usage:
#   bash scripts/frontier/frontier_cosmoflow_headline.sh
#
# Env overrides:
#   FITPP_N_TRAIN   default 524288   (full dataset; can drop to 61440
#                                     for an old-mini comparison or
#                                     8192 for a quick smoke)
#   FITPP_N_EPOCHS  default 3        (cold + 2 warm)
#   N_NODES         default 1        (16 in the user's example)
#   SERVERS_PER_NODE default 2
#   GPUS_PER_NODE   default 8
#   COSMOFLOW_DATA  default $FITPP_PFS_DATA_ROOT/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2
#                   (parent dir containing train/ and validation/)
#   WALLTIME        default 12:00:00

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-1}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-2}"
GPUS_PER_NODE="${GPUS_PER_NODE:-8}"
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))
N_TRAIN="${FITPP_N_TRAIN:-524288}"
N_EPOCHS="${FITPP_N_EPOCHS:-3}"
WALLTIME="${WALLTIME:-12:00:00}"
COSMOFLOW_DATA="${COSMOFLOW_DATA:-${FITPP_PFS_DATA_ROOT}/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2}"

if [ ! -d "$COSMOFLOW_DATA/train" ]; then
    echo "ERROR: cosmoflow data not extracted at $COSMOFLOW_DATA/train/" >&2
    echo "       (expected layout: <data>/train/*.tfrecord + <data>/validation/*.tfrecord)" >&2
    exit 1
fi
TRAIN_FILE_COUNT=$(ls "$COSMOFLOW_DATA/train" 2>/dev/null | wc -l)
echo "[driver] cosmoflow data:  $COSMOFLOW_DATA  ($TRAIN_FILE_COUNT train files)"
if [ "$TRAIN_FILE_COUNT" -lt "$N_TRAIN" ]; then
    echo "WARNING: requested n_train=$N_TRAIN exceeds available file count $TRAIN_FILE_COUNT" >&2
fi

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_cosmoflow_headline
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/cosmoflow_headline/${RUN_TAG}"
mkdir -p "$ROOT_DIR"

submit_side() {
    local SIDE="$1"        # FitCachePP or Pure_CF
    local JOB_DIR="$ROOT_DIR/${SIDE}"
    mkdir -p "$JOB_DIR"
    local USE_LD_PRELOAD=""
    local CACHE_SUBDIR="${SIDE}_${RUN_TAG}"
    if [ "$SIDE" = "FitCachePP" ]; then
        USE_LD_PRELOAD="LD_PRELOAD=\"\$FITPP_CLIENT_LIB\""
    fi
    cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J cosmoflow_${SIDE}
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -o $JOB_DIR/cosmoflow_${SIDE}-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="$JOB_DIR"
mkdir -p "\$RESULTS_DIR"
cd "\$RESULTS_DIR"

# FitCache env. BBPATH=/tmp per the user's known-working HVAC pattern
# (cf. [[feedback-frontier-multi-gpu-pattern]]); we keep the cache dirs
# under /tmp too rather than /mnt/bb/$USER to match.
export BBPATH=/tmp
export FitCache_DATA_DIR="$COSMOFLOW_DATA"
export FitCache_DRAM_PATH=/tmp/fitcachepp_${CACHE_SUBDIR}_dram
export FitCache_NVME_PATH=/tmp/fitcachepp_${CACHE_SUBDIR}_nvme
export FitCache_DRAM_CAPACITY=\$((100 * 1024 * 1024 * 1024))    # 100 GiB
export FitCache_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))   # 1.5 TiB  (fits 1.4 TB v2 set)
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$TOTAL_SERVERS
export FitCache_CROSS_JOB=0

# MIOpen knobs (mandatory on Frontier — SQLite kernel cache breaks on NFS \$HOME)
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_\$SLURM_PROCID
mkdir -p \$MIOPEN_USER_DB_PATH

# TF / XLA / ROCm bitcode mismatch workarounds (see commit history)
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3

mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

echo "[\$SIDE] nodes=\$SLURM_NNODES  total_servers=\$FitCache_SERVER_COUNT  gpus_per_node=$GPUS_PER_NODE"
echo "[\$SIDE] data=\$FitCache_DATA_DIR"

# ---- spawn FitCachePP servers (always, even on Pure_CF; Pure_CF just doesn't LD_PRELOAD)
echo "[\$SIDE] launching $TOTAL_SERVERS servers via srun"
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE \\
     --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS \\
     > "\$RESULTS_DIR/server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=\$!
sleep 15

# ---- training command (one srun, one task per GPU)
# Wrapper that each srun task runs: sets LD_PRELOAD (for FitCachePP)
# then invokes python train.py. horovod.init() inside the python picks
# up rank/size from the SLURM/PMI env.
WRAPPER="\$RESULTS_DIR/train_wrapper.sh"
cat > "\$WRAPPER" <<'WEOF'
#!/bin/bash
cd \$FITPP_COSMOFLOW_DIR
${USE_LD_PRELOAD} \$FITPP_PYTHON_TF \\
    \$FITPP_COSMOFLOW_DIR/train.py -d \\
    --data-dir "\$FitCache_DATA_DIR" \\
    --n-train $N_TRAIN \\
    --n-epochs $N_EPOCHS
WEOF
chmod +x "\$WRAPPER"

echo "[\$SIDE] launching training: \$((N_NODES * $GPUS_PER_NODE)) GPUs total"
START=\$SECONDS
srun -N $N_NODES -c4 --gpus-per-node=$GPUS_PER_NODE --ntasks-per-gpu=1 \\
     --cpu-bind=cores "\$WRAPPER" 2>&1 | tee "\$RESULTS_DIR/train_\${SLURM_JOB_ID}.log"
TRAIN_RC=\${PIPESTATUS[0]}
END=\$SECONDS
echo "[\$SIDE] training wall=\$((END - START))s rc=\$TRAIN_RC"

# ---- teardown
echo "[\$SIDE] tearing down servers"
kill -TERM \$SERVER_SRUN_PID 2>/dev/null || true
sleep 5

OPEN_RPC=\$(grep -cE "Open RPC: requested path" \$RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
MMAP=\$(grep -cE "mmap on tracked fd|mmap: redirected to anon" \$RESULTS_DIR/fitcache_intercept_log.*.0 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
EPOCH_LINES=\$(grep -cE "time:.*[0-9]+s/epoch" \$RESULTS_DIR/train_\${SLURM_JOB_ID}.log 2>/dev/null || echo 0)
echo "----- \$SIDE summary -----"
echo "  Training wall:    \$((END - START))s"
echo "  Open RPCs:        \$OPEN_RPC"
echo "  mmap-redirects:   \$MMAP"
echo "  epochs completed: \$EPOCH_LINES"
EOF
    chmod +x "$JOB_DIR/job.sh"
    sbatch --parsable "$JOB_DIR/job.sh"
}

JOB_FITCACHEPP=$(submit_side FitCachePP)
JOB_PURE_CF=$(submit_side Pure_CF)
echo "FitCachePP run: $JOB_FITCACHEPP   -> $ROOT_DIR/FitCachePP/"
echo "Pure_CF    run: $JOB_PURE_CF      -> $ROOT_DIR/Pure_CF/"

cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
job_fitcachepp=$JOB_FITCACHEPP
job_pure_cf=$JOB_PURE_CF
n_nodes=$N_NODES
gpus_per_node=$GPUS_PER_NODE
servers_per_node=$SERVERS_PER_NODE
total_servers=$TOTAL_SERVERS
n_train=$N_TRAIN
n_epochs=$N_EPOCHS
data_dir=$COSMOFLOW_DATA
walltime=$WALLTIME
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
