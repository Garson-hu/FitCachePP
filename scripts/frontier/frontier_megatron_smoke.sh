#!/bin/bash
# Frontier compute-node Megatron mmap-interceptor smoke.
#
# Same idea as the login-node smoke, but runs inside a SLURM allocation
# so we exercise:
#   - real /mnt/bb/$USER NVMe (not /tmp)
#   - Slingshot Mercury (not TCP loopback)
#   - the FitCache_DRAM/NVMe tier paths the real Megatron launcher uses
#
# Submits one job that:
#   1. Loads modules + FitCache env
#   2. Spawns 4 fitcache_server processes
#   3. Runs megatron_io_only_iter.py under LD_PRELOAD against the real
#      enwik8 .bin/.idx
#   4. Reports engagement signals from the in-job server log
#
# Usage:
#   bash scripts/frontier/frontier_megatron_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_megatron_smoke
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/megatron_smoke/${RUN_TAG}"
mkdir -p "$ROOT_DIR"

# Inline job script — sbatch reads it from stdin so the BASH_SOURCE/CWD
# guards in the launcher scripts don't have to fight SLURM's slurm_script
# copy.
JOB_SCRIPT="$ROOT_DIR/job.sh"
cat > "$JOB_SCRIPT" <<EOF
#!/bin/bash
#SBATCH -J megatron_smoke
#SBATCH -t 00:30:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -o $ROOT_DIR/megatron_smoke-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO

# Resolve site (modules, paths, etc.)
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

DATA_PREFIX="\${FITPP_MEGATRON_CORPUS_PREFIX}"
NODE=\$(hostname -s)
RESULTS_DIR="$ROOT_DIR"
cd "\$RESULTS_DIR"

# FitCache env
export FitCache_DATA_DIR="\$(dirname \$DATA_PREFIX)"
export FitCache_DRAM_PATH=\$FITPP_LOCAL_CACHE_ROOT/fitcachepp_megatron_smoke_dram
export FitCache_NVME_PATH=\$FITPP_LOCAL_CACHE_ROOT/fitcachepp_megatron_smoke_nvme
export FitCache_DRAM_CAPACITY=\$((4 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((16 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=1
export FitCache_CROSS_JOB=0
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

echo "[smoke] node=\$NODE  cache root=\$FITPP_LOCAL_CACHE_ROOT"
echo "[smoke] data=\$DATA_PREFIX"

# Start fitcache_server
SLURM_PROCID=0 FitCache_SERVER_PORT=5555 \\
    "\$FITPP_SERVER_BIN" 1 \\
    > "\$RESULTS_DIR/server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_PID=\$!
echo "[smoke] server pid=\$SERVER_PID"
sleep 5

# Run the IndexedDataset iterator under LD_PRELOAD
LD_PRELOAD="\$FITPP_CLIENT_LIB" \\
FITPP_MEGATRON_DIR="\$FITPP_MEGATRON_DIR" \\
    "\$FITPP_PYTHON_TORCH" \\
    "\$FITPP_REPO/benchmarks/megatron/megatron_io_only_iter.py" \\
    --data-prefix "\$DATA_PREFIX" \\
    --num-iters 500 --seq-length 1024 --batch-size 4

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
echo "Results dir: $ROOT_DIR"
echo
echo "Watch with: squeue -u \$USER -j $JOB_ID"
echo "Output:     $ROOT_DIR/megatron_smoke-${JOB_ID}.out"
