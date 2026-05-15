#!/bin/bash
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_dinov2
#
# DINOv2 workload-generalization run (FitCache++ wrapping self-supervised
# image pretraining). Defends the workload-generalization claim at the
# small-files / nested-directory I/O shape.
#
# NOTE: this workload is currently mmap-blocked — DINOv2's ImageNet22k
# ExtraDataset uses mmap-backed tarball slicing, which the LD_PRELOAD
# client doesn't intercept (see
# benchmarks/results/arc/workload_generalization/megatron_mmap_limitation.md).
# Script preserved + ported as portable scaffolding for when an mmap
# interceptor lands.
#
# Submit like:
#
#   FITPP_SITE=frontier
#   source benchmarks/sites/${FITPP_SITE}.sh
#   sbatch -p "$FITPP_SLURM_PARTITION" \
#          ${FITPP_SLURM_ACCOUNT:+--account=$FITPP_SLURM_ACCOUNT} \
#          -o "$FITPP_RESULTS_ROOT/dinov2/FitCachePP_dinov2-%j.out" \
#          benchmarks/dinov2/PDSW_FITPP_dinov2.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/../sites" ]; then
    if [ -n "${FITPP_REPO:-}" ] && [ -d "$FITPP_REPO/benchmarks/sites" ]; then
        SCRIPT_DIR="$FITPP_REPO/benchmarks/dinov2"
    elif [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -d "$SLURM_SUBMIT_DIR/benchmarks/sites" ]; then
        SCRIPT_DIR="$SLURM_SUBMIT_DIR/benchmarks/dinov2"
    else
        echo "ERROR: cannot locate benchmarks/sites — set FITPP_REPO" >&2
        exit 1
    fi
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh"

# ---------------- USER CONFIGURATION (overrides via env) ----------------
# Defaults point at the site's PFS data root for the imagenet22k dirs.
DINOV2_DATASET_ROOT="${DINOV2_DATASET_ROOT:-${FITPP_PFS_DATA_ROOT}/imagenet22k}"
DINOV2_EXTRA_DIR="${DINOV2_EXTRA_DIR:-${FITPP_PFS_DATA_ROOT}/imagenet22k_extra}"
DINOV2_PYTHON="${DINOV2_PYTHON:-${FITPP_PYTHON_DINOV2}}"
DINOV2_CONFIG="${DINOV2_CONFIG:-${FITPP_REPO}/benchmarks/dinov2/configs/vits14_smoke.yaml}"
TRAIN_ITERS="${TRAIN_ITERS:-1000}"
GPUS_PER_NODE="${GPUS_PER_NODE:-$FITPP_GPUS_PER_NODE_DEFAULT}"
# ------------------------------------------------------------------------

export FitCache_DATA_DIR="$DINOV2_DATASET_ROOT"

NODE_DEFAULT="$(scontrol show hostnames $SLURM_JOB_NODELIST 2>/dev/null | head -1)"
export SERVER_NODES="${SERVER_NODES:-$NODE_DEFAULT}"
export CLIENT_NODES="${CLIENT_NODES:-$NODE_DEFAULT}"
export SERVERS_PER_NODE="${SERVERS_PER_NODE:-$FITPP_SERVERS_PER_NODE_DEFAULT}"
export FitCache_SERVER_COUNT="${FitCache_SERVER_COUNT:-$SERVERS_PER_NODE}"

export FitCache_LOG_LEVEL=600
export RDMAV_FORK_SAFE=1

# Many-small-files workload — generous DRAM tier, NVMe spill.
export FitCache_DRAM_PATH="${FitCache_DRAM_PATH:-${FITPP_LOCAL_CACHE_ROOT}/fitcachepp_dinov2_dram}"
export FitCache_NVME_PATH="${FitCache_NVME_PATH:-${FITPP_LOCAL_CACHE_ROOT}/fitcachepp_dinov2_nvme}"
export FitCache_DRAM_CAPACITY="${FitCache_DRAM_CAPACITY:-$((100 * 1024 * 1024 * 1024))}"
export FitCache_NVME_CAPACITY="${FitCache_NVME_CAPACITY:-$((500 * 1024 * 1024 * 1024))}"
export BBPATH="$FitCache_NVME_PATH"

export FitCache_CROSS_JOB="${FitCache_CROSS_JOB:-1}"
export FitCache_CLUSTER_REGISTRY_DIR="${FitCache_CLUSTER_REGISTRY_DIR:-${FITPP_PFS_REGISTRY_ROOT}/dinov2}"

export RESULTS_DIR="${RESULTS_DIR:-${FITPP_RESULTS_ROOT}/dinov2}"
mkdir -p "$RESULTS_DIR" "$FitCache_CLUSTER_REGISTRY_DIR"

# DINOv2's train.py takes a config file + a few CLI overrides.
export DINOV2_TRAIN_CMD=(
  "$DINOV2_PYTHON"
  "$FITPP_DINOV2_DIR/dinov2/train/train.py"
  --config-file "$DINOV2_CONFIG"
  --output-dir "$RESULTS_DIR/dinov2_run_${SLURM_JOB_ID}"
  train.dataset_path="ImageNet22k:root=$DINOV2_DATASET_ROOT:extra=$DINOV2_EXTRA_DIR"
  optim.epochs=1
  train.OFFICIAL_EPOCH_LENGTH="$TRAIN_ITERS"
)

export FITCACHE_CLIENT_LAUNCHER="$FITPP_REPO/benchmarks/dinov2/command_dinov2_FITPP.sh"
exec "$FITPP_REPO/benchmarks/cosmoflow/PDSW_FITPP_inner.sh"
