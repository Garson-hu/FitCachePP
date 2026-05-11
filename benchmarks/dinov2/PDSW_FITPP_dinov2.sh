#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_dinov2
#SBATCH -o /home/ghu4/hvac/FitCachePP/benchmarks/results/dinov2/FitCachePP_dinov2-%j.out
#
# DINOv2 workload-generalization run (FitCache++ wrapping self-supervised
# image pretraining). Defends the workload-generalization claim at the
# small-files / nested-directory I/O shape.
#
# Prerequisites:
#   1. DINOv2 source tree at /home/ghu4/hvac/benchmark/dinov2 (cloned).
#   2. ImageNet-22k images at DINOV2_DATASET_ROOT (the parent directory
#      holding the `nNNNNNNNN/img_*.jpg` tree).
#   3. ImageNet-22k metadata generated via dinov2/data/datasets/image_net_22k.py:
#      - entries.txt
#      - class_ids.txt
#      (See dinov2/README.md "ImageNet-22k" section for the one-time
#      generation step.)
#   4. PyTorch + CUDA + DINOv2's pip deps installed in the python env at
#      DINOV2_PYTHON.

# ---------------- USER CONFIGURATION (edit before submission) ----------------
DINOV2_DATASET_ROOT="${DINOV2_DATASET_ROOT:-/mnt/beegfs/ghu4/hvac/imagenet22k}"
DINOV2_EXTRA_DIR="${DINOV2_EXTRA_DIR:-/mnt/beegfs/ghu4/hvac/imagenet22k_extra}"
DINOV2_PYTHON="${DINOV2_PYTHON:-/home/ghu4/hvac/rlibrary/miniconda3/envs/dinov2/bin/python3}"
DINOV2_CONFIG="${DINOV2_CONFIG:-/home/ghu4/hvac/FitCachePP/benchmarks/dinov2/configs/vits14_smoke.yaml}"
TRAIN_ITERS="${TRAIN_ITERS:-1000}"
GPUS_PER_NODE="${GPUS_PER_NODE:-1}"
# ----------------------------------------------------------------------------

# FitCache_DATA_DIR is the dataset root. Both the metadata files at the
# root AND the deeply-nested per-class image files will be substring-
# matched by the LD_PRELOAD client filter (fitcache_client.cpp:116).
export FitCache_DATA_DIR="$DINOV2_DATASET_ROOT"

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

# DINOv2 reads many small image files — DRAM tier should be sized
# generously; NVMe absorbs the spill.
export FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_dinov2_dram
export FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_dinov2_nvme
export FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))   # 100 GiB
export FitCache_NVME_CAPACITY=$((500 * 1024 * 1024 * 1024))   # 500 GiB
export BBPATH=$FitCache_NVME_PATH

export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR=/mnt/beegfs/ghu4/fitcachepp_registry_dinov2

export RESULTS_DIR=/home/ghu4/hvac/FitCachePP/benchmarks/results/dinov2
mkdir -p "$RESULTS_DIR" "$FitCache_CLUSTER_REGISTRY_DIR"

# DINOv2's train.py takes a config file + a few CLI overrides. The dataset
# path is supplied via `train.dataset_path` in YAML, which we override on
# the CLI so we can pin it to our ImageNet22k root.
export DINOV2_TRAIN_CMD=(
  "$DINOV2_PYTHON"
  /home/ghu4/hvac/benchmark/dinov2/dinov2/train/train.py
  --config-file "$DINOV2_CONFIG"
  --output-dir "$RESULTS_DIR/dinov2_run_${SLURM_JOB_ID}"
  train.dataset_path="ImageNet22k:root=$DINOV2_DATASET_ROOT:extra=$DINOV2_EXTRA_DIR"
  optim.epochs=1
  train.OFFICIAL_EPOCH_LENGTH="$TRAIN_ITERS"
)

export FITCACHE_CLIENT_LAUNCHER=/home/ghu4/hvac/FitCachePP/benchmarks/dinov2/command_dinov2_FITPP.sh
exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
