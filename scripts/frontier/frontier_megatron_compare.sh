#!/bin/bash
# Frontier Megatron FitCachePP-vs-Pure_CF comparison.
#
# Submits TWO compute-node jobs (different nodes) running Megatron-LM
# pretrain_gpt.py for the same workload — one with LD_PRELOAD'd
# libfitcache_client.so (the FitCachePP side), one without (the Pure_CF
# baseline). Goal: clean per-iter wall-clock comparison defending the
# workload-generalization claim on LLM-style pretraining.
#
# Megatron model: tiny GPT (12 layers, 768 hidden, 12 heads) that fits on
# 1 MI250X GCD. Apex/TE bypassed via --no-masked-softmax-fusion and
# friends. Data is the staged enwik8 .bin/.idx pair (58 MB tokenized).
#
# Usage:
#   bash scripts/frontier/frontier_megatron_compare.sh

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

TRAIN_ITERS="${TRAIN_ITERS:-200}"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_megatron_compare
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/megatron_compare/${RUN_TAG}"
mkdir -p "$ROOT_DIR"

DATA_PREFIX="${FITPP_PFS_DATA_ROOT}/megatron/enwik8/enwik8_text_document"
VOCAB="${FITPP_PFS_DATA_ROOT}/megatron/tokenizer/gpt2-vocab.json"
MERGES="${FITPP_PFS_DATA_ROOT}/megatron/tokenizer/gpt2-merges.txt"

if [ ! -f "${DATA_PREFIX}.bin" ] || [ ! -f "${DATA_PREFIX}.idx" ]; then
    echo "ERROR: tokenized corpus missing at ${DATA_PREFIX}.{bin,idx}" >&2
    exit 1
fi
if [ ! -f "$VOCAB" ] || [ ! -f "$MERGES" ]; then
    echo "ERROR: GPT-2 tokenizer files missing under ${FITPP_PFS_DATA_ROOT}/megatron/tokenizer/" >&2
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
#SBATCH -J megatron_${SIDE}
#SBATCH -t 01:00:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -o $JOB_DIR/megatron_${SIDE}-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="$JOB_DIR"
cd "\$RESULTS_DIR"

# FitCache env (applies to both sides; Pure_CF just doesn't LD_PRELOAD)
export FitCache_DATA_DIR="\$(dirname $DATA_PREFIX)"
export FitCache_DRAM_PATH=\$FITPP_LOCAL_CACHE_ROOT/megatron_compare_dram
export FitCache_NVME_PATH=\$FITPP_LOCAL_CACHE_ROOT/megatron_compare_nvme
export FitCache_DRAM_CAPACITY=\$((4 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((16 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=1
export FitCache_CROSS_JOB=0
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

# Spawn the FitCache server. The Pure_CF side spawns it too but skips
# LD_PRELOAD so the python process bypasses it entirely.
SLURM_PROCID=0 FitCache_SERVER_PORT=5555 \\
    "\$FITPP_SERVER_BIN" 1 \\
    > "\$RESULTS_DIR/server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_PID=\$!
sleep 5

export MASTER_ADDR=\$(hostname)
export MASTER_PORT=6000
export RANK=0
export WORLD_SIZE=1
export LOCAL_RANK=0

MEGATRON_ARGS=(
    --num-layers 12
    --hidden-size 768
    --num-attention-heads 12
    --seq-length 1024
    --max-position-embeddings 1024
    --micro-batch-size 4
    --global-batch-size 4
    --lr 1.5e-4
    --train-iters $TRAIN_ITERS
    --lr-decay-iters \$(($TRAIN_ITERS * 9 / 10))
    --lr-warmup-iters \$(($TRAIN_ITERS / 100))
    --weight-decay 1e-2
    --clip-grad 1.0
    --bf16
    --data-path $DATA_PREFIX
    --vocab-file $VOCAB
    --merge-file $MERGES
    --tokenizer-type GPT2BPETokenizer
    --split 949,50,1
    --log-interval 10
    --eval-interval 100000
    --eval-iters 0
    --save-interval 100000
    --no-masked-softmax-fusion
    --no-bias-gelu-fusion
    --no-async-tensor-model-parallel-allreduce
    --transformer-impl local
    --distributed-backend gloo
)

echo "=== side=$SIDE start \$(date) ==="
START=\$SECONDS
${USE_LD_PRELOAD} \\
    "\$FITPP_PYTHON_TORCH" \\
    "\$FITPP_MEGATRON_DIR/pretrain_gpt.py" "\${MEGATRON_ARGS[@]}" 2>&1
END=\$SECONDS
ELAPSED=\$((END - START))
echo "=== side=$SIDE done \$(date) wall=\${ELAPSED}s ==="

kill -TERM \$SERVER_PID 2>/dev/null || true
sleep 2

# Engagement signals — only meaningful for the FitCachePP side
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
train_iters=$TRAIN_ITERS
data_prefix=$DATA_PREFIX
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
