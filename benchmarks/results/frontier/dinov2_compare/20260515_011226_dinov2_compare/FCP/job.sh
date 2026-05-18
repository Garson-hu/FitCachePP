#!/bin/bash
#SBATCH -J dinov2_FCP
#SBATCH -t 00:30:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/dinov2_compare/20260515_011226_dinov2_compare/FCP/dinov2_FCP-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP

set -euo pipefail
cd $FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/dinov2_compare/20260515_011226_dinov2_compare/FCP"
cd "$RESULTS_DIR"

export FitCache_DATA_DIR="/lustre/orion/gen008/proj-shared/ghu4/data/dinov2/imagenet_synth"
export FitCache_DRAM_PATH=$FITPP_LOCAL_CACHE_ROOT/dinov2_compare_dram
export FitCache_NVME_PATH=$FITPP_LOCAL_CACHE_ROOT/dinov2_compare_nvme
export FitCache_DRAM_CAPACITY=$((4 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((16 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"
export FitCache_SERVER_COUNT=1
export FitCache_CROSS_JOB=0
mkdir -p "$FitCache_DRAM_PATH" "$FitCache_NVME_PATH"

SLURM_PROCID=0 FitCache_SERVER_PORT=5557 \
    "$FITPP_SERVER_BIN" 1 \
    > "$RESULTS_DIR/server_${SLURM_JOB_ID}.log" 2>&1 &
SERVER_PID=$!
sleep 5

echo "=== mode=FCP start $(date) ==="
START=$SECONDS
LD_PRELOAD="$FITPP_CLIENT_LIB" \
    "$FITPP_PYTHON_TORCH" \
    "$FITPP_REPO/benchmarks/dinov2/dinov2_io_only_iter.py" \
    --root "/lustre/orion/gen008/proj-shared/ghu4/data/dinov2/imagenet_synth" \
    --num-iters 2000 \
    --batch-size 4
END=$SECONDS
ELAPSED=$((END - START))
echo "=== mode=FCP done $(date) wall=${ELAPSED}s ==="

kill -TERM $SERVER_PID 2>/dev/null || true
sleep 2

OPEN_RPC=$(grep -cE "Open RPC: requested path" fitcache_server_log.${SERVER_PID}.* 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
MMAP=$(grep -cE "mmap on tracked fd|mmap: redirected to anon" fitcache_intercept_log.*.0 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
echo "----- mode=FCP summary -----"
echo "  Wall-clock: ${ELAPSED}s"
echo "  Open RPCs:  $OPEN_RPC"
echo "  mmap-redir: $MMAP"
