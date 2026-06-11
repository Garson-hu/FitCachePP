#!/bin/bash
#SBATCH -J t1_mega
#SBATCH -t 02:00:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/tier1_staging_reps_v3/megatron_N1/t1_mega-%j.out
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
RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/tier1_staging_reps_v3/megatron_N1"
mkdir -p "$RESULTS_DIR"; cd "$RESULTS_DIR"
PY="$FITPP_PYTHON_TORCH"
BENCH="$FITPP_REPO/benchmarks/megatron/llm_coverage_bench.py"
TOOL="$FITPP_REPO/tools/fitcache_cached_path"
export SRC_DIR="/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb"
export PLAIN_DIR=/mnt/bb/$USER/t1_staged_plain
export BBPATH=/mnt/bb/$USER
export FitCache_DATA_DIR="$SRC_DIR"
export FitCache_DRAM_PATH=/tmp/t1_mega_dram
export FitCache_NVME_PATH=/mnt/bb/$USER/t1_mega_nvme
export FitCache_DRAM_CAPACITY=$((40 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((3000 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"
export FitCache_SERVER_COUNT=4
export FitCache_CROSS_JOB=0
export STAGE_FILES="/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0000.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0001.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0002.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0003.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0004.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0005.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0006.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0007.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0008.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0009.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0010.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0011.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0012.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0013.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0014.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0015.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0016.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0017.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0018.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0019.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0020.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0021.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0022.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0023.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0024.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0025.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0026.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0027.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0028.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0029.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0030.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0031.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0032.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0033.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0034.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0035.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0036.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0037.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0038.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0039.bin /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0000.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0001.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0002.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0003.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0004.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0005.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0006.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0007.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0008.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0009.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0010.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0011.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0012.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0013.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0014.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0015.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0016.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0017.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0018.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0019.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0020.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0021.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0022.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0023.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0024.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0025.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0026.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0027.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0028.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0029.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0030.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0031.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0032.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0033.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0034.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0035.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0036.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0037.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0038.idx /lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb/shard_0039.idx"

run_bench () { # label preload logf
  if [ -n "$2" ]; then
    srun -N 1 -n 1 --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \
      "LD_PRELOAD=\"$2\" \"$PY\" \"$BENCH\" --data-dir \"$4\" --num-shards 40 --coverage 1.0 --n-chunks 4000 --epochs 2 --seed 0 --label \"$1\"" \
      2>&1 | tee "$RESULTS_DIR/$3"
  else
    srun -N 1 -n 1 --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \
      "\"$PY\" \"$BENCH\" --data-dir \"$4\" --num-shards 40 --coverage 1.0 --n-chunks 4000 --epochs 2 --seed 0 --label \"$1\"" \
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
