#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_megatron
#SBATCH -o /home/ghu4/hvac/FitCachePP/benchmarks/results/megatron/FitCachePP_megatron-%j.out
#
# Megatron-LM workload-generalization run (FitCache++ wrapping a GPT-style
# LLM pretraining job). Defends the workload-generalization claim from
# tpds_extension/04_experiment_plan.md §IV-H by routing Megatron's
# indexed-binary I/O through FitCache.
#
# Prerequisites the user must satisfy before submission:
#   1. Megatron-LM source tree at /home/ghu4/hvac/benchmark/Megatron-LM
#      (already cloned; --depth 1 source only, no datasets/weights).
#   2. Tokenized data at MEGATRON_DATA_PREFIX (e.g., RedPajama or a Pile
#      slice run through tools/preprocess_data.py). Megatron expects a
#      paired <prefix>.bin (token blob) and <prefix>.idx (offset table).
#   3. Tokenizer files at MEGATRON_VOCAB_FILE + MEGATRON_MERGE_FILE
#      (gpt2-vocab.json + gpt2-merges.txt).
#   4. PyTorch + CUDA + apex installed in the python env at
#      /home/ghu4/hvac/rlibrary/miniconda3/envs/<env_name>. Megatron
#      requires apex's fused kernels.
#
# What this script does:
#   1. Sets FitCache_DATA_DIR to the dataset root (parent of the .bin/.idx
#      files), so the LD_PRELOAD client's substring path-filter
#      (fitcache_client.cpp:116) catches every Megatron data open.
#   2. Sets the env vars FitCache_PORTS_CFG_DIR / log paths via
#      PDSW_FITPP_inner.sh (server cd's to RESULTS_DIR, log4c lands here).
#   3. Launches Megatron's pretrain_gpt.py through LD_PRELOAD'd python
#      via torchrun. The training command opens .bin/.idx repeatedly;
#      FitCache promotes them into the local cache tier on first read,
#      and serves subsequent epochs from cache.

# ---------------- USER CONFIGURATION (edit before submission) ----------------
MEGATRON_DATA_PREFIX="${MEGATRON_DATA_PREFIX:-/mnt/beegfs/ghu4/hvac/megatron_pile_train_001/pile_slice_text_document}"
MEGATRON_VOCAB_FILE="${MEGATRON_VOCAB_FILE:-/mnt/beegfs/ghu4/hvac/megatron_assets/gpt2-vocab.json}"
MEGATRON_MERGE_FILE="${MEGATRON_MERGE_FILE:-/mnt/beegfs/ghu4/hvac/megatron_assets/gpt2-merges.txt}"
MEGATRON_PYTHON="${MEGATRON_PYTHON:-/home/ghu4/hvac/rlibrary/miniconda3/envs/megatron/bin/python3}"
TRAIN_ITERS="${TRAIN_ITERS:-1000}"
GPUS_PER_NODE="${GPUS_PER_NODE:-1}"
# ----------------------------------------------------------------------------

# FitCache_DATA_DIR is the PARENT of the .bin/.idx pair so the substring
# path-filter catches both.
export FitCache_DATA_DIR="$(dirname "$MEGATRON_DATA_PREFIX")"

# Server topology — same shape as the CosmoFlow scripts.
NODE_DEFAULT="$(scontrol show hostnames $SLURM_JOB_NODELIST 2>/dev/null | head -1)"
NODE_DEFAULT="${NODE_DEFAULT:-c66}"
export SERVER_NODES="${SERVER_NODES:-$NODE_DEFAULT}"
export CLIENT_NODES="${CLIENT_NODES:-$NODE_DEFAULT}"
export SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
export FitCache_SERVER_COUNT="${FitCache_SERVER_COUNT:-4}"

export FitCache_LOG_LEVEL=600
export RDMAV_FORK_SAFE=1
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH

# Tier paths for the cache.
export FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_megatron_dram
export FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_megatron_nvme
export FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))   # 100 GiB
export FitCache_NVME_CAPACITY=$((500 * 1024 * 1024 * 1024))   # 500 GiB
export BBPATH=$FitCache_NVME_PATH

# Cross-job ON for the workload-generalization runs (so two Megatron jobs
# pointed at the same dataset can share cache content via the registry).
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR=/mnt/beegfs/ghu4/fitcachepp_registry_megatron

export RESULTS_DIR=/home/ghu4/hvac/FitCachePP/benchmarks/results/megatron
mkdir -p "$RESULTS_DIR" "$FitCache_CLUSTER_REGISTRY_DIR"

# The Megatron training command — built up here, exec'd via LD_PRELOAD by
# command_megatron_FITPP.sh which the inner launcher invokes.
export MEGATRON_TRAIN_CMD=(
  torchrun
    --nproc_per_node="$GPUS_PER_NODE"
    --nnodes=1
    --master_addr=localhost
    --master_port=6000
    /home/ghu4/hvac/benchmark/Megatron-LM/pretrain_gpt.py
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
    --save-interval 100000   # don't bother saving in the smoke
    --no-async-tensor-model-parallel-allreduce
)

# Hand off to the shared launcher. We override CLIENT_COMMAND so the
# inner.sh runs Megatron's torchrun-wrapped pretrain instead of the
# CosmoFlow command_CF_FITPP.sh.
export FITCACHE_CLIENT_LAUNCHER=/home/ghu4/hvac/FitCachePP/benchmarks/megatron/command_megatron_FITPP.sh
exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
