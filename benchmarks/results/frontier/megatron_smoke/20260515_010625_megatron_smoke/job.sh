#!/bin/bash
#SBATCH -J megatron_smoke
#SBATCH -t 00:30:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/megatron_smoke/20260515_010625_megatron_smoke/megatron_smoke-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP

set -euo pipefail
cd $FITPP_REPO

# Resolve site (modules, paths, etc.)
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

DATA_PREFIX="${FITPP_MEGATRON_CORPUS_PREFIX}"
NODE=$(hostname -s)
RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/megatron_smoke/20260515_010625_megatron_smoke"
cd "$RESULTS_DIR"

# FitCache env
export FitCache_DATA_DIR="$(dirname $DATA_PREFIX)"
export FitCache_DRAM_PATH=$FITPP_LOCAL_CACHE_ROOT/fitcachepp_megatron_smoke_dram
export FitCache_NVME_PATH=$FITPP_LOCAL_CACHE_ROOT/fitcachepp_megatron_smoke_nvme
export FitCache_DRAM_CAPACITY=$((4 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((16 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"
export FitCache_SERVER_COUNT=1
export FitCache_CROSS_JOB=0
mkdir -p "$FitCache_DRAM_PATH" "$FitCache_NVME_PATH"

echo "[smoke] node=$NODE  cache root=$FITPP_LOCAL_CACHE_ROOT"
echo "[smoke] data=$DATA_PREFIX"

# Start fitcache_server
SLURM_PROCID=0 FitCache_SERVER_PORT=5555 \
    "$FITPP_SERVER_BIN" 1 \
    > "$RESULTS_DIR/server_${SLURM_JOB_ID}.log" 2>&1 &
SERVER_PID=$!
echo "[smoke] server pid=$SERVER_PID"
sleep 5

# Run the IndexedDataset iterator under LD_PRELOAD
LD_PRELOAD="$FITPP_CLIENT_LIB" \
FITPP_MEGATRON_DIR="$FITPP_MEGATRON_DIR" \
    "$FITPP_PYTHON_TORCH" \
    "$FITPP_REPO/benchmarks/megatron/megatron_io_only_iter.py" \
    --data-prefix "$DATA_PREFIX" \
    --num-iters 500 --seq-length 1024 --batch-size 4

echo "[smoke] tearing down"
kill -TERM $SERVER_PID 2>/dev/null || true
sleep 2

OPEN_RPC=$(grep -cE "Open RPC: requested path" fitcache_server_log.${SERVER_PID}.* 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
MMAP=$(grep -cE "mmap on tracked fd|mmap: redirected to anon" fitcache_intercept_log.*.0 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
echo "----- engagement signals -----"
echo "    Open RPCs: $OPEN_RPC"
echo "    mmap-redirects: $MMAP"
