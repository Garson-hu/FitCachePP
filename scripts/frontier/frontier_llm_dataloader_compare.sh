#!/bin/bash
# Frontier dataloader-heavy LLM benchmark: FitCachePP vs Pure_CF.
#
# Submits TWO compute-node jobs (different nodes) running
# llm_dataloader_bench.py over a 10 GB synthetic Megatron IndexedDataset.
# Pattern is the same as frontier_megatron_compare.sh (the
# correctness-only compare) but the iterator runs many more iterations
# and the corpus is large enough that random reads don't fit trivially
# in page cache between samples.
#
# Reports cold (first N iters) / warm (last N iters) / amortized
# throughput in tokens/s and MB/s plus step-time so we can compare
# Mercury-fronted reads against direct Lustre.
#
# Usage:
#   bash scripts/frontier/frontier_llm_dataloader_compare.sh
#
# Tunables (env):
#   TOTAL_ITERS  default 20000
#   COLD_ITERS   default 2000
#   WARM_ITERS   default 2000
#   BATCH_SIZE   default 16
#   SEQ_LENGTH   default 1024
#   DATA_PREFIX  default synth_10gb_text_document under FITPP_PFS_DATA_ROOT/megatron/synth_10gb/

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

TOTAL_ITERS="${TOTAL_ITERS:-20000}"
COLD_ITERS="${COLD_ITERS:-2000}"
WARM_ITERS="${WARM_ITERS:-2000}"
BATCH_SIZE="${BATCH_SIZE:-16}"
SEQ_LENGTH="${SEQ_LENGTH:-1024}"
DATA_PREFIX="${DATA_PREFIX:-${FITPP_PFS_DATA_ROOT}/megatron/synth_10gb/synth_10gb_text_document}"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_llm_dataloader_compare
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/llm_dataloader_compare/${RUN_TAG}"
mkdir -p "$ROOT_DIR"

if [ ! -f "${DATA_PREFIX}.bin" ] || [ ! -f "${DATA_PREFIX}.idx" ]; then
    echo "ERROR: synthetic corpus missing at ${DATA_PREFIX}.{bin,idx}" >&2
    echo "       Generate it via benchmarks/megatron/generate_synth_corpus.py" >&2
    exit 1
fi

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
#SBATCH -J llmdl_${SIDE}
#SBATCH -t 00:20:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -q hackathon
#SBATCH -o $JOB_DIR/llmdl_${SIDE}-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="$JOB_DIR"
mkdir -p "\$RESULTS_DIR"
cd "\$RESULTS_DIR"

export BBPATH=/tmp
# FitCache env (used only when LD_PRELOAD is set)
export FitCache_DATA_DIR=\$(dirname "$DATA_PREFIX")
export FitCache_DRAM_PATH=/tmp/fitcachepp_llmdl_${CACHE_SUBDIR}_dram
export FitCache_NVME_PATH=/tmp/fitcachepp_llmdl_${CACHE_SUBDIR}_nvme
export FitCache_DRAM_CAPACITY=\$((20 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((40 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=4
export FitCache_CROSS_JOB=0
export FITPP_TIMING_DUMP_ON_EXIT=1
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

echo "[$SIDE] data=$DATA_PREFIX  total=$TOTAL_ITERS cold=$COLD_ITERS warm=$WARM_ITERS batch=$BATCH_SIZE seq=$SEQ_LENGTH"

# Spawn 4 FitCache servers in the same pattern as cosmoflow (matches the
# 2026-05-17 fix). Pure_CF spawns them too but skips LD_PRELOAD so they
# go unused.
echo "[$SIDE] launching servers via srun"
srun -N 1 -n 4 --ntasks-per-node=4 --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" 4 \\
     > "\$RESULTS_DIR/server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=\$!
sleep 10

# Optional: try to evict page cache so the cold-iters sample really is
# cold. Best-effort; if posix_fadvise is unavailable, this is a no-op.
\$FITPP_PYTHON_TORCH -c "
import os
for ext in ('.bin', '.idx'):
    p = '$DATA_PREFIX' + ext
    try:
        fd = os.open(p, os.O_RDONLY)
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        os.close(fd)
        print('[cache-evict] POSIX_FADV_DONTNEED on', p)
    except Exception as e:
        print('[cache-evict] could not evict', p, e)
"

WRAPPER="\$RESULTS_DIR/run_bench.sh"
cat > "\$WRAPPER" <<'WEOF'
#!/bin/bash
${USE_LD_PRELOAD} "\$FITPP_PYTHON_TORCH" \\
    "\$FITPP_REPO/benchmarks/megatron/llm_dataloader_bench.py" \\
    --data-prefix "$DATA_PREFIX" \\
    --total-iters $TOTAL_ITERS \\
    --cold-iters $COLD_ITERS \\
    --warm-iters $WARM_ITERS \\
    --batch-size $BATCH_SIZE \\
    --seq-length $SEQ_LENGTH
WEOF
chmod +x "\$WRAPPER"

echo "=== side=$SIDE start \$(date) ==="
START=\$SECONDS
srun -N 1 -n 1 --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores \\
     "\$WRAPPER" 2>&1 | tee "\$RESULTS_DIR/bench_\${SLURM_JOB_ID}.log"
END=\$SECONDS
ELAPSED=\$((END - START))
echo "=== side=$SIDE done \$(date) wall=\${ELAPSED}s ==="

kill -TERM \$SERVER_SRUN_PID 2>/dev/null || true
sleep 3

OPEN_RPC=\$(grep -cE "Open RPC: requested path" \$RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
MMAP=\$(grep -cE "mmap on tracked fd|mmap: redirected to anon" \$RESULTS_DIR/fitcache_intercept_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
echo "----- side=$SIDE summary -----"
echo "  Wall:            \${ELAPSED}s"
echo "  Open RPCs:       \$OPEN_RPC"
echo "  mmap-redirects:  \$MMAP"
# Pull the bench's own cold/warm/amortized summary lines forward
grep -E "^  cold:|^  warm:|^  amortized:|open_wall" \$RESULTS_DIR/bench_\${SLURM_JOB_ID}.log || true
EOF
    chmod +x "$JOB_DIR/job.sh"
    sbatch --parsable "$JOB_DIR/job.sh"
}

JOB_FCP=$(submit_side FitCachePP)
JOB_PCF=$(submit_side Pure_CF)
echo "FitCachePP run: $JOB_FCP -> $ROOT_DIR/FitCachePP/"
echo "Pure_CF    run: $JOB_PCF -> $ROOT_DIR/Pure_CF/"

cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
fitcachepp_job=$JOB_FCP
purecf_job=$JOB_PCF
data_prefix=$DATA_PREFIX
total_iters=$TOTAL_ITERS
cold_iters=$COLD_ITERS
warm_iters=$WARM_ITERS
batch_size=$BATCH_SIZE
seq_length=$SEQ_LENGTH
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
