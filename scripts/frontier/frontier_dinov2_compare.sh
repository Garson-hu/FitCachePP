#!/bin/bash
# Frontier DINOv2 FitCachePP-vs-Pure_CF comparison.
#
# DINOv2's canonical training requires the real ImageNet-22k loader with
# entries.txt / class_ids.txt metadata, which is gated on Kaggle/ILSVRC
# registration for the 1.4 TB dataset. The defensible alternative — and
# the one used in the ARC workload-generalization analysis — is the
# I/O-only iterator (`dinov2_io_only_iter.py`) which exercises the same
# per-image open + mmap pattern as DINOv2's actual training without the
# GPU compute or distributed-init scaffolding. We benchmark that under
# FitCachePP vs Pure_CF.
#
# Submits TWO compute-node jobs (one per side). Each iterates over the
# synthetic ImageNet-22k stand-in (20 classes × 50 images), opening +
# mmapping each picked image; the FitCachePP side has libfitcache_client
# LD_PRELOAD'd, the Pure_CF side runs without.
#
# Usage:
#   bash scripts/frontier/frontier_dinov2_compare.sh

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

NUM_ITERS="${NUM_ITERS:-2000}"
BATCH_SIZE="${BATCH_SIZE:-4}"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_dinov2_compare
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/dinov2_compare/${RUN_TAG}"
mkdir -p "$ROOT_DIR"

DINOV2_ROOT="${FITPP_PFS_DATA_ROOT}/dinov2/imagenet_synth"
if [ ! -d "$DINOV2_ROOT" ]; then
    echo "ERROR: imagenet stand-in missing at $DINOV2_ROOT" >&2
    exit 1
fi

submit_side() {
    local SIDE="$1"        # FitCachePP or Pure_CF
    local JOB_DIR="$ROOT_DIR/${SIDE}"
    mkdir -p "$JOB_DIR"
    local USE_LD_PRELOAD=""
    if [ "$SIDE" = "FitCachePP" ]; then
        USE_LD_PRELOAD="LD_PRELOAD=\"\$FITPP_CLIENT_LIB\""
    fi

    cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J dinov2_${SIDE}
#SBATCH -t 00:30:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -o $JOB_DIR/dinov2_${SIDE}-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="$JOB_DIR"
cd "\$RESULTS_DIR"

export FitCache_DATA_DIR="$DINOV2_ROOT"
export FitCache_DRAM_PATH=\$FITPP_LOCAL_CACHE_ROOT/dinov2_compare_dram
export FitCache_NVME_PATH=\$FITPP_LOCAL_CACHE_ROOT/dinov2_compare_nvme
export FitCache_DRAM_CAPACITY=\$((4 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((16 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=1
export FitCache_CROSS_JOB=0
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

SLURM_PROCID=0 FitCache_SERVER_PORT=5557 \\
    "\$FITPP_SERVER_BIN" 1 \\
    > "\$RESULTS_DIR/server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_PID=\$!
sleep 5

echo "=== side=$SIDE start \$(date) ==="
START=\$SECONDS
${USE_LD_PRELOAD} \\
    "\$FITPP_PYTHON_TORCH" \\
    "\$FITPP_REPO/benchmarks/dinov2/dinov2_io_only_iter.py" \\
    --root "$DINOV2_ROOT" \\
    --num-iters $NUM_ITERS \\
    --batch-size $BATCH_SIZE
END=\$SECONDS
ELAPSED=\$((END - START))
echo "=== side=$SIDE done \$(date) wall=\${ELAPSED}s ==="

kill -TERM \$SERVER_PID 2>/dev/null || true
sleep 2

OPEN_RPC=\$(grep -cE "Open RPC: requested path" fitcache_server_log.\${SERVER_PID}.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
MMAP=\$(grep -cE "mmap on tracked fd|mmap: redirected to anon" fitcache_intercept_log.*.0 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
echo "----- side=$SIDE summary -----"
echo "  Wall-clock: \${ELAPSED}s"
echo "  Open RPCs:  \$OPEN_RPC"
echo "  mmap-redir: \$MMAP"
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
num_iters=$NUM_ITERS
batch_size=$BATCH_SIZE
data_root=$DINOV2_ROOT
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
