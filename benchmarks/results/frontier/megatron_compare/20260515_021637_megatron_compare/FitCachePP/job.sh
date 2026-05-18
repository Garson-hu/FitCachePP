#!/bin/bash
#SBATCH -J megatron_FitCachePP
#SBATCH -t 01:00:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/megatron_compare/20260515_021637_megatron_compare/FitCachePP/megatron_FitCachePP-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP

set -euo pipefail
cd $FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/megatron_compare/20260515_021637_megatron_compare/FitCachePP"
cd "$RESULTS_DIR"

# FitCache env (applies to both sides; Pure_CF just doesn't LD_PRELOAD)
export FitCache_DATA_DIR="$(dirname /lustre/orion/gen008/proj-shared/ghu4/data/megatron/enwik8/enwik8_text_document)"
export FitCache_DRAM_PATH=$FITPP_LOCAL_CACHE_ROOT/megatron_compare_dram
export FitCache_NVME_PATH=$FITPP_LOCAL_CACHE_ROOT/megatron_compare_nvme
export FitCache_DRAM_CAPACITY=$((4 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((16 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"
export FitCache_SERVER_COUNT=1
export FitCache_CROSS_JOB=0
mkdir -p "$FitCache_DRAM_PATH" "$FitCache_NVME_PATH"

# Spawn the FitCache server. The Pure_CF side spawns it too but skips
# LD_PRELOAD so the python process bypasses it entirely.
SLURM_PROCID=0 FitCache_SERVER_PORT=5555 \
    "$FITPP_SERVER_BIN" 1 \
    > "$RESULTS_DIR/server_${SLURM_JOB_ID}.log" 2>&1 &
SERVER_PID=$!
sleep 5

export MASTER_ADDR=$(hostname)
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
    --train-iters 200
    --lr-decay-iters $((200 * 9 / 10))
    --lr-warmup-iters $((200 / 100))
    --weight-decay 1e-2
    --clip-grad 1.0
    --bf16
    --data-path /lustre/orion/gen008/proj-shared/ghu4/data/megatron/enwik8/enwik8_text_document
    --vocab-file /lustre/orion/gen008/proj-shared/ghu4/data/megatron/tokenizer/gpt2-vocab.json
    --merge-file /lustre/orion/gen008/proj-shared/ghu4/data/megatron/tokenizer/gpt2-merges.txt
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

echo "=== side=FitCachePP start $(date) ==="
START=$SECONDS
LD_PRELOAD="$FITPP_CLIENT_LIB" \
    "$FITPP_PYTHON_TORCH" \
    "$FITPP_MEGATRON_DIR/pretrain_gpt.py" "${MEGATRON_ARGS[@]}" 2>&1
END=$SECONDS
ELAPSED=$((END - START))
echo "=== side=FitCachePP done $(date) wall=${ELAPSED}s ==="

kill -TERM $SERVER_PID 2>/dev/null || true
sleep 2

# Engagement signals — only meaningful for the FitCachePP side
OPEN_RPC=$(grep -cE "Open RPC: requested path" fitcache_server_log.${SERVER_PID}.* 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
MMAP=$(grep -cE "mmap on tracked fd|mmap: redirected to anon" fitcache_intercept_log.*.0 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
echo "----- side=FitCachePP summary -----"
echo "  Wall-clock: ${ELAPSED}s"
echo "  Open RPCs:  $OPEN_RPC"
echo "  mmap-redir: $MMAP"
