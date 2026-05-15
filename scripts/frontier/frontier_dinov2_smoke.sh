#!/bin/bash
# Frontier compute-node DINOv2 mmap-interceptor smoke.
# Same shape as frontier_megatron_smoke.sh but exercises the
# many-small-files mmap pattern via dinov2_io_only_iter.py against
# the synthetic ImageNet stand-in at $FITPP_PFS_DATA_ROOT/dinov2/imagenet_synth.

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_dinov2_smoke
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/dinov2_smoke/${RUN_TAG}"
mkdir -p "$ROOT_DIR"

JOB_SCRIPT="$ROOT_DIR/job.sh"
cat > "$JOB_SCRIPT" <<EOF
#!/bin/bash
#SBATCH -J dinov2_smoke
#SBATCH -t 00:30:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -o $ROOT_DIR/dinov2_smoke-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO

# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

DINOV2_ROOT="\${FITPP_PFS_DATA_ROOT}/dinov2/imagenet_synth"
NODE=\$(hostname -s)
RESULTS_DIR="$ROOT_DIR"
cd "\$RESULTS_DIR"

export FitCache_DATA_DIR="\$DINOV2_ROOT"
export FitCache_DRAM_PATH=\$FITPP_LOCAL_CACHE_ROOT/fitcachepp_dinov2_smoke_dram
export FitCache_NVME_PATH=\$FITPP_LOCAL_CACHE_ROOT/fitcachepp_dinov2_smoke_nvme
export FitCache_DRAM_CAPACITY=\$((4 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((16 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=1
export FitCache_CROSS_JOB=0
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

echo "[smoke] node=\$NODE  data=\$DINOV2_ROOT"

SLURM_PROCID=0 FitCache_SERVER_PORT=5557 \\
    "\$FITPP_SERVER_BIN" 1 \\
    > "\$RESULTS_DIR/server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_PID=\$!
echo "[smoke] server pid=\$SERVER_PID"
sleep 5

LD_PRELOAD="\$FITPP_CLIENT_LIB" \\
    "\$FITPP_PYTHON_TORCH" \\
    "\$FITPP_REPO/benchmarks/dinov2/dinov2_io_only_iter.py" \\
    --root "\$DINOV2_ROOT" \\
    --num-iters 500 --batch-size 4

echo "[smoke] tearing down"
kill -TERM \$SERVER_PID 2>/dev/null || true
sleep 2

OPEN_RPC=\$(grep -cE "Open RPC: requested path" fitcache_server_log.\${SERVER_PID}.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
MMAP=\$(grep -cE "mmap on tracked fd|mmap: redirected to anon" fitcache_intercept_log.*.0 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
echo "----- engagement signals -----"
echo "    Open RPCs: \$OPEN_RPC"
echo "    mmap-redirects: \$MMAP"
EOF

chmod +x "$JOB_SCRIPT"
JOB_ID=$(sbatch --parsable "$JOB_SCRIPT")
echo "Submitted: $JOB_ID"
echo "Output:    $ROOT_DIR/dinov2_smoke-${JOB_ID}.out"
