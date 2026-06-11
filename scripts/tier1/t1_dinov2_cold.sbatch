#!/bin/bash
#SBATCH -J t1_dino_cold
#SBATCH -t 02:00:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/tier1_staging_reps_v3/dinov2_N1_cold/t1_dino-%j.out
# Tier 1.1 (manual-staging baseline) + Tier 1.2 (3 repetitions), N=1.
# Three arms x 3 reps: Native_mmap_PFS, Staged_native_NVMe (plain cp +
# native run on local copies = the reviewer's "staging script" control),
# FitCachePP_warmhit (hash-bin pre-stage + servers + preload).
# Each bench invocation runs --epochs 2, so each rep yields 2 epoch samples.
# For GNN the native reps 2-3 additionally measure the page-cache-resident
# native regime (72 GiB working set < RAM), which is the Tier 1.3 data point.
export FITPP_SITE=frontier
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP
set -uo pipefail
cd $FITPP_REPO
source benchmarks/sites/_resolve.sh
RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/tier1_staging_reps_v3/dinov2_N1_cold"
mkdir -p "$RESULTS_DIR"; cd "$RESULTS_DIR"
PY="$FITPP_PYTHON_TORCH"
BENCH="$FITPP_REPO/benchmarks/dinov2/cc12m_mmap_bench.py"
TOOL="$FITPP_REPO/tools/fitcache_cached_path"
export SRC_DIR="/lustre/orion/gen008/proj-shared/ghu4/data/dinov2/cc12m_wds"
export PLAIN_DIR=/mnt/bb/$USER/t1_staged_plain
export BBPATH=/mnt/bb/$USER
export FitCache_DATA_DIR="$SRC_DIR"
export FitCache_DRAM_PATH=/tmp/t1_dino_dram
export FitCache_NVME_PATH=/mnt/bb/$USER/t1_dino_nvme
export FitCache_DRAM_CAPACITY=$((256 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((3000 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"
export FitCache_SERVER_COUNT=4
export FitCache_CROSS_JOB=0
export STAGE_FILES="$(ls /lustre/orion/gen008/proj-shared/ghu4/data/dinov2/cc12m_wds/*.tar | head -996 | tr '\n' ' ')"

run_bench () { # label preload logf
  if [ -n "$2" ]; then
    srun -N 1 -n 1 --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \
      "LD_PRELOAD=\"$2\" \"$PY\" \"$BENCH\" --data-dir \"$4\" --num-shards 996 --epochs 1 --decode-every 500 --shared --label \"$1\"" \
      2>&1 | tee "$RESULTS_DIR/$3"
  else
    srun -N 1 -n 1 --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \
      "\"$PY\" \"$BENCH\" --data-dir \"$4\" --num-shards 996 --epochs 1 --decode-every 500 --shared --label \"$1\"" \
      2>&1 | tee "$RESULTS_DIR/$3"
  fi
}

echo "##### DINOv2 true-cold native, 1 epoch #####"
T0=$SECONDS
run_bench "Native_mmap_PFS" "" "native_cold_1ep.log" "$SRC_DIR"
echo "[arm-timing] native_cold_1ep wall=$((SECONDS - T0))s"
echo "[done] $(date -Is)"
