#!/bin/bash
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_megatron
#
# Megatron-LM workload-generalization run (FitCache++ wrapping a GPT-style
# LLM pretraining job). Defends the workload-generalization claim from
# tpds_extension/04_experiment_plan.md §IV-H by routing Megatron's
# indexed-binary I/O through FitCache.
#
# NOTE: this workload is currently mmap-blocked — Megatron uses numpy.memmap
# for .bin/.idx access, which the LD_PRELOAD client does not intercept
# (see benchmarks/results/arc/workload_generalization/megatron_mmap_limitation.md).
# Script is preserved + ported as portable scaffolding for when an mmap
# interceptor lands.
#
# IMPORTANT: this script is site-portable. Pass partition/account/output on
# the sbatch CLI:
#
#   FITPP_SITE=frontier
#   source benchmarks/sites/${FITPP_SITE}.sh
#   sbatch -p "$FITPP_SLURM_PARTITION" \
#          ${FITPP_SLURM_ACCOUNT:+--account=$FITPP_SLURM_ACCOUNT} \
#          -o "$FITPP_RESULTS_ROOT/megatron/FitCachePP_megatron-%j.out" \
#          benchmarks/megatron/PDSW_FITPP_megatron.sh

# Resolve site (sets $FITPP_REPO and friends). Under sbatch, BASH_SOURCE
# points at /var/spool/slurmd/.../slurm_script — fall back to $FITPP_REPO.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/../sites" ]; then
    if [ -n "${FITPP_REPO:-}" ] && [ -d "$FITPP_REPO/benchmarks/sites" ]; then
        SCRIPT_DIR="$FITPP_REPO/benchmarks/megatron"
    elif [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -d "$SLURM_SUBMIT_DIR/benchmarks/sites" ]; then
        SCRIPT_DIR="$SLURM_SUBMIT_DIR/benchmarks/megatron"
    else
        echo "ERROR: cannot locate benchmarks/sites — set FITPP_REPO" >&2
        exit 1
    fi
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh"

# ---------------- USER CONFIGURATION (overrides via env) ----------------
# Defaults pull dataset paths from the site config; override per submission
# if your slice lives elsewhere.
MEGATRON_DATA_PREFIX="${MEGATRON_DATA_PREFIX:-${FITPP_MEGATRON_CORPUS_PREFIX}}"
MEGATRON_VOCAB_FILE="${MEGATRON_VOCAB_FILE:-${FITPP_MEGATRON_TOKENIZER_DIR}/gpt2-vocab.json}"
MEGATRON_MERGE_FILE="${MEGATRON_MERGE_FILE:-${FITPP_MEGATRON_TOKENIZER_DIR}/gpt2-merges.txt}"
MEGATRON_PYTHON="${MEGATRON_PYTHON:-${FITPP_PYTHON_TORCH}}"
TRAIN_ITERS="${TRAIN_ITERS:-1000}"
GPUS_PER_NODE="${GPUS_PER_NODE:-$FITPP_GPUS_PER_NODE_DEFAULT}"
# ------------------------------------------------------------------------

# FitCache_DATA_DIR is the PARENT of the .bin/.idx pair so the substring
# path-filter catches both.
export FitCache_DATA_DIR="$(dirname "$MEGATRON_DATA_PREFIX")"

NODE_DEFAULT="$(scontrol show hostnames $SLURM_JOB_NODELIST 2>/dev/null | head -1)"
export SERVER_NODES="${SERVER_NODES:-$NODE_DEFAULT}"
export CLIENT_NODES="${CLIENT_NODES:-$NODE_DEFAULT}"
export SERVERS_PER_NODE="${SERVERS_PER_NODE:-$FITPP_SERVERS_PER_NODE_DEFAULT}"
export FitCache_SERVER_COUNT="${FitCache_SERVER_COUNT:-$SERVERS_PER_NODE}"

export FitCache_LOG_LEVEL=600
export RDMAV_FORK_SAFE=1

# Tier paths under the site's per-node cache root.
export FitCache_DRAM_PATH="${FitCache_DRAM_PATH:-${FITPP_LOCAL_CACHE_ROOT}/fitcachepp_megatron_dram}"
export FitCache_NVME_PATH="${FitCache_NVME_PATH:-${FITPP_LOCAL_CACHE_ROOT}/fitcachepp_megatron_nvme}"
export FitCache_DRAM_CAPACITY="${FitCache_DRAM_CAPACITY:-$((100 * 1024 * 1024 * 1024))}"
export FitCache_NVME_CAPACITY="${FitCache_NVME_CAPACITY:-$((500 * 1024 * 1024 * 1024))}"
export BBPATH="$FitCache_NVME_PATH"

# Cross-job ON so two Megatron jobs at the same dataset share the cache.
export FitCache_CROSS_JOB="${FitCache_CROSS_JOB:-1}"
export FitCache_CLUSTER_REGISTRY_DIR="${FitCache_CLUSTER_REGISTRY_DIR:-${FITPP_PFS_REGISTRY_ROOT}/megatron}"

export RESULTS_DIR="${RESULTS_DIR:-${FITPP_RESULTS_ROOT}/megatron}"
mkdir -p "$RESULTS_DIR" "$FitCache_CLUSTER_REGISTRY_DIR"

# The Megatron training command — exec'd via LD_PRELOAD by
# command_megatron_FITPP.sh which the inner launcher invokes.
export MEGATRON_TRAIN_CMD=(
  torchrun
    --nproc_per_node="$GPUS_PER_NODE"
    --nnodes=1
    --master_addr=localhost
    --master_port=6000
    "$FITPP_MEGATRON_DIR/pretrain_gpt.py"
    --num-layers 12 --hidden-size 768 --num-attention-heads 12
    --seq-length 1024 --max-position-embeddings 1024
    --micro-batch-size 4 --global-batch-size 16
    --lr 1.5e-4 --train-iters "$TRAIN_ITERS"
    --lr-decay-iters $((TRAIN_ITERS * 9 / 10))
    --lr-warmup-iters $((TRAIN_ITERS / 100))
    --weight-decay 1e-2 --clip-grad 1.0 --fp16
    --data-path "$MEGATRON_DATA_PREFIX"
    --vocab-file "$MEGATRON_VOCAB_FILE"
    --merge-file "$MEGATRON_MERGE_FILE"
    --tokenizer-type GPT2BPETokenizer
    --split 949,50,1
    --log-interval 10 --eval-interval 100 --eval-iters 5
    --save-interval 100000
    --no-async-tensor-model-parallel-allreduce
)
export MEGATRON_PYTHON

# Hand off to the shared launcher. FITCACHE_CLIENT_LAUNCHER selects the
# Megatron-specific torchrun wrapper instead of CosmoFlow's.
export FITCACHE_CLIENT_LAUNCHER="$FITPP_REPO/benchmarks/megatron/command_megatron_FITPP.sh"
exec "$FITPP_REPO/benchmarks/cosmoflow/PDSW_FITPP_inner.sh"
