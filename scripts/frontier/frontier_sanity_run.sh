#!/bin/bash
# Frontier sanity-run driver: submits two single-GPU back-to-back jobs that
# compare FitCachePP vs Pure_CF on the cosmoUniverse_..._mini dataset.
# Successful completion lets us answer the primary handoff question — does
# FitCachePP per-epoch wall-clock beat Pure_CF on Frontier at single-GPU
# scale on the mini dataset — without waiting for the full 169 GB
# train_61440/ extraction.
#
# Usage:
#   bash scripts/frontier_sanity_run.sh
#
# Submits two jobs. Each runs TPDS_FITPP.sh on 1 Frontier node. The
# FitCachePP job goes through libfitcache_client.so + 4 fitcache_server
# processes on local NVMe; the Pure_CF job runs train.py directly against
# the Lustre dataset.

set -euo pipefail
cd "$(dirname "$0")/.."

export FITPP_SITE=frontier
# Mini dataset has 1024 train files. n_train=1024 matches the file count
# exactly (no resampling). 3 epochs = cold + 2 warm gives at least one
# warm-epoch wall-clock to compare.
export FITPP_N_TRAIN=1024
export FITPP_N_EPOCHS=3

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_sanity
FITCACHEPP_DIR=benchmarks/results/frontier/sanity/FitCachePP_${RUN_TAG}
PURE_CF_DIR=benchmarks/results/frontier/sanity/Pure_CF_${RUN_TAG}
mkdir -p "$FITCACHEPP_DIR" "$PURE_CF_DIR"

# Frontier batch partition needs -C nvme to mount the per-node burst buffer
# (/mnt/bb/$USER); without it $FITPP_LOCAL_CACHE_ROOT doesn't exist.
SBATCH_BASE=(
    -p batch
    --account=gen008
    -C nvme
    -N 1
    -t 01:00:00
    --export=ALL
)

echo "--- submitting FitCachePP sanity ---"
RESULTS_DIR="$PWD/$FITCACHEPP_DIR" \
sbatch "${SBATCH_BASE[@]}" \
    -J FitCachePP_sanity \
    -o "$FITCACHEPP_DIR/FitCachePP-%j.out" \
    benchmarks/cosmoflow/TPDS_FITPP.sh

echo "--- submitting Pure_CF sanity ---"
RESULTS_DIR="$PWD/$PURE_CF_DIR" \
FITPP_PURE_CF=1 \
sbatch "${SBATCH_BASE[@]}" \
    -J Pure_CF_sanity \
    -o "$PURE_CF_DIR/Pure_CF-%j.out" \
    benchmarks/cosmoflow/TPDS_FITPP.sh

echo "--- queued ---"
squeue -u "$USER" 2>&1 | tail -5
echo "Run-tag: $RUN_TAG"
echo "FitCachePP results: $FITCACHEPP_DIR"
echo "Pure_CF results:    $PURE_CF_DIR"
