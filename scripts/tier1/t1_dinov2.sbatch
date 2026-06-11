#!/bin/bash
#SBATCH -J t1_dino
#SBATCH -t 02:00:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/tier1_staging_reps_v3/dinov2_N1/t1_dino-%j.out
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
RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/tier1_staging_reps_v3/dinov2_N1"
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
      "LD_PRELOAD=\"$2\" \"$PY\" \"$BENCH\" --data-dir \"$4\" --num-shards 996 --epochs 2 --decode-every 500 --shared --label \"$1\"" \
      2>&1 | tee "$RESULTS_DIR/$3"
  else
    srun -N 1 -n 1 --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \
      "\"$PY\" \"$BENCH\" --data-dir \"$4\" --num-shards 996 --epochs 2 --decode-every 500 --shared --label \"$1\"" \
      2>&1 | tee "$RESULTS_DIR/$3"
  fi
}

echo "##### ARM 2: Staged_native_NVMe (plain cp + native local run) x3 #####"
T0=$SECONDS
srun -N 1 -n 1 bash -c '
  mkdir -p "$PLAIN_DIR"
  # symlink the full dataset layout, then replace the touched subset with
  # real local copies — non-staged files behave identically to the
  # FitCachePP arm (which also leaves them on Lustre).
  for f in "$SRC_DIR"/*; do ln -sf "$f" "$PLAIN_DIR/$(basename "$f")"; done
  for f in $STAGE_FILES; do
    b=$(basename "$f"); rm -f "$PLAIN_DIR/$b"; cp "$f" "$PLAIN_DIR/$b"
  done
  echo "[plain-stage] $(hostname): $(du -sLb "$PLAIN_DIR" | cut -f1) bytes visible"
'
echo "[arm-timing] plain-stage wall=$((SECONDS - T0))s"
for r in 1 2 3; do
  T0=$SECONDS
  run_bench "Staged_native_NVMe" "" "staged_rep$r.log" "$PLAIN_DIR"
  echo "[arm-timing] staged rep$r wall=$((SECONDS - T0))s"
done

echo "##### ARM 3: FitCachePP_warmhit x3 (hash-bin pre-stage + servers) #####"
T0=$SECONDS
srun -N 1 -n 1 bash -c '
  mkdir -p "$FitCache_NVME_PATH"
  for f in $STAGE_FILES; do
    dst=$("$FITPP_REPO/tools/fitcache_cached_path" "$f" "$FitCache_NVME_PATH")
    mkdir -p "$(dirname "$dst")"
    if [ ! -f "$dst" ] || [ "$(stat -c %s "$dst" 2>/dev/null || echo 0)" != "$(stat -c %s "$f")" ]; then
      cp "$f" "$dst"
    fi
  done
  echo "[fitpp-stage] $(hostname): $(du -sb "$FitCache_NVME_PATH" | cut -f1) bytes staged"
'
echo "[arm-timing] fitpp-stage wall=$((SECONDS - T0))s"
mkdir -p "$FitCache_DRAM_PATH"
srun -N 1 -n 4 --ntasks-per-node=4 --cpus-per-task=1 --cpu-bind=cores \
     "$FITPP_SERVER_BIN" 4 > "$RESULTS_DIR/server.log" 2>&1 &
SPID=$!
sleep 15
for r in 1 2 3; do
  T0=$SECONDS
  run_bench "FitCachePP_warmhit" "$FITPP_CLIENT_LIB" "fitcachepp_rep$r.log" "$SRC_DIR"
  echo "[arm-timing] fitcachepp rep$r wall=$((SECONDS - T0))s"
done
kill -TERM $SPID 2>/dev/null || true; sleep 3

echo "##### ARM 4: Native_mmap_PFS x2 post-traffic (OSS-warm; matches the May sweep's measurement condition) #####"
for r in 1 2; do
  T0=$SECONDS
  run_bench "Native_mmap_PFS" "" "native_post_rep$r.log" "$SRC_DIR"
  echo "[arm-timing] native_post rep$r wall=$((SECONDS - T0))s"
done
echo "[done] $(date -Is)"
