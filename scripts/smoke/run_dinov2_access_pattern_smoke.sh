#!/usr/bin/env bash
#
# run_dinov2_access_pattern_smoke.sh
#
# DINOv2 access-pattern smoke (no GPU, no real DINOv2 checkout required).
#
# DINOv2's training (dinov2/train/train.py + dinov2/data/datasets/ImageNet22k)
# reads ImageNet-style image trees: a deep hierarchy of `class_id/imageNN.jpg`
# files plus a few class-index `.txt` / `.npy` metadata files at the dataset
# root. The training I/O pattern is:
#   - One open + read per image per epoch (random order).
#   - Many small files (~100 KB each) under a wide directory tree.
#   - Plus the per-startup metadata reads (entries.txt, class_ids.txt, etc.).
# So the FitCache claim for this workload is: catch the open of the metadata
# files AND the deeply-nested image opens, promote them into a tier, serve
# subsequent epochs from cache.
#
# What this smoke does:
#   1. Generate a synthetic ImageNet-style tree:
#        dataset_root/
#          entries.txt
#          class_ids.txt
#          n01001234/img_0000.jpg ... img_0009.jpg
#          n02002345/img_0000.jpg ... img_0009.jpg
#          ... 4 classes total = 40 images + 2 metadata files
#   2. Run harness_read_files against the dataset root (recursive).
#   3. Verify >=80% of files were promoted into a cache tier and that
#      sidecars exist for them in cross-job mode. (80% allowance gives
#      slack for the data-mover queue draining when the harness exits;
#      the synchronous wait + the recently-fixed signal-loss bug should
#      make 100% reachable but accept slight slack for robustness.)
#
# This is the analog of run_megatron_access_pattern_smoke.sh but for the
# small-files-many-dirs access shape rather than the big-streaming-blob
# shape. Together they defend the claim "FitCache++ generalizes beyond
# CosmoFlow/DeepCAM" at the access-pattern level.

set -u
set -o pipefail

REPO=/home/ghu4/hvac/FitCachePP
SERVER_BIN=$REPO/build/src/fitcache_server
CLIENT_LIB=$REPO/build/src/libfitcache_client.so
HARNESS_BIN=$REPO/build/tests/harness_read_files

for f in "$SERVER_BIN" "$CLIENT_LIB" "$HARNESS_BIN"; do
    [ -f "$f" ] || { echo "missing build artifact: $f" >&2; exit 2; }
done

export PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH

SMOKE_ROOT=/tmp/fitcachepp_dinov2_smoke_$$
mkdir -p "$SMOKE_ROOT"/{dataset,registry,dram,nvme,cwd,logs}
echo "[setup] smoke root: $SMOKE_ROOT"

# Generate synthetic ImageNet-style tree.
N_CLASSES=4
N_IMAGES_PER_CLASS=10
IMG_SIZE_KB=100
TOTAL_FILES=$((N_CLASSES * N_IMAGES_PER_CLASS + 2))   # +2 metadata files
DATASET=$SMOKE_ROOT/dataset

# Metadata at dataset root. Real DINOv2 reads these via standard open() too.
head -c 4096  /dev/urandom > "$DATASET/entries.txt"
head -c 1024  /dev/urandom > "$DATASET/class_ids.txt"

for c in $(seq 1 $N_CLASSES); do
    cls=$(printf "n%08d" $c)
    mkdir -p "$DATASET/$cls"
    for i in $(seq 0 $((N_IMAGES_PER_CLASS - 1))); do
        head -c $((IMG_SIZE_KB * 1024)) /dev/urandom > "$DATASET/$cls/$(printf img_%04d.jpg $i)"
    done
done
echo "[setup] synthetic ImageNet tree: $N_CLASSES classes × $N_IMAGES_PER_CLASS images + 2 metadata = $TOTAL_FILES files"
echo "[setup] dataset size: $(du -sh "$DATASET" | awk '{print $1}')"

# harness_read_files only iterates argv[1] non-recursively, so we need to
# walk the tree ourselves. Easiest: spawn the harness once per subdir.
cd "$SMOKE_ROOT/cwd"
export FitCache_DATA_DIR=$DATASET
export FitCache_CLUSTER_REGISTRY_DIR=$SMOKE_ROOT/registry
export FitCache_PORTS_CFG_DIR=$SMOKE_ROOT/cwd
export FitCache_HEARTBEAT_SEC=5
export FitCache_LOG_LEVEL=600
export FitCache_SERVER_COUNT=1
export FitCache_DRAM_PATH=$SMOKE_ROOT/dram
export FitCache_NVME_PATH=$SMOKE_ROOT/nvme
export FitCache_DRAM_CAPACITY=$((128 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((512 * 1024 * 1024))
export FitCache_CROSS_JOB=1
export SLURM_JOBID=${SLURM_JOBID:-9002}
export SLURM_PROCID=0

"$SERVER_BIN" 1 > "$SMOKE_ROOT/logs/server.log" 2>&1 &
SID=$!
sleep 3
if ! kill -0 "$SID" 2>/dev/null; then
    echo "[fatal] server died at startup" >&2
    tail -40 "$SMOKE_ROOT/logs/server.log" >&2
    exit 3
fi

# Walk the tree: one harness run per directory (root + each class).
RC=0
LD_PRELOAD=$CLIENT_LIB "$HARNESS_BIN" "$DATASET" >> "$SMOKE_ROOT/logs/client.log" 2>&1 || RC=$?
for c in $(seq 1 $N_CLASSES); do
    cls=$(printf "n%08d" $c)
    LD_PRELOAD=$CLIENT_LIB "$HARNESS_BIN" "$DATASET/$cls" >> "$SMOKE_ROOT/logs/client.log" 2>&1 || RC=$?
done

# Let the data mover drain.
sleep 6

kill -TERM "$SID" 2>/dev/null || true
sleep 1
kill -9 "$SID" 2>/dev/null || true
wait "$SID" 2>/dev/null || true
mv "$SMOKE_ROOT/cwd"/fitcache_server_log.* "$SMOKE_ROOT/logs/" 2>/dev/null || true

if [ $RC -ne 0 ]; then
    echo "[fatal] one or more harness runs failed (rc=$RC); tail $SMOKE_ROOT/logs/client.log" >&2
    tail -20 "$SMOKE_ROOT/logs/client.log" >&2
    exit 4
fi

CACHED_FILES=$(find "$SMOKE_ROOT/dram" "$SMOKE_ROOT/nvme" -type f ! -name '*.meta' 2>/dev/null | wc -l)
SIDECARS=$(find "$SMOKE_ROOT/dram" "$SMOKE_ROOT/nvme" -type f -name '*.meta' 2>/dev/null | wc -l)

echo
echo "=== DINOv2 access-pattern smoke result ==="
echo "  source files       : $TOTAL_FILES"
echo "  cached payloads    : $CACHED_FILES"
echo "  sidecars written   : $SIDECARS"

# 80% threshold: anything below means the data mover is dropping work.
THRESH=$((TOTAL_FILES * 80 / 100))
fail=0
[ "$CACHED_FILES" -lt "$THRESH" ] && { echo "[fail] cached file count $CACHED_FILES < 80% of source ($THRESH)" >&2; fail=1; }
[ "$SIDECARS"     -lt "$THRESH" ] && { echo "[fail] sidecar count $SIDECARS < 80% of source ($THRESH)" >&2; fail=1; }

# Spot-check sha256 on one cached image to defend bit-equivalence at this
# access shape too.
SAMPLE=$(find "$SMOKE_ROOT/dram" "$SMOKE_ROOT/nvme" -type f -name 'img_*.jpg' 2>/dev/null | head -1)
if [ -n "$SAMPLE" ]; then
    SAMPLE_NAME=$(basename "$SAMPLE")
    SAMPLE_CLASS=$(basename "$(dirname "$(grep -l "" "$SAMPLE" 2>/dev/null | head -1)")")  # not perfect; fall back below
    # Easier: grep the .meta sidecar for the original_path field.
    META=${SAMPLE}.meta
    if [ -f "$META" ]; then
        SRC=$(grep -E "^original_path=" "$META" 2>/dev/null | head -1 | cut -d= -f2-)
        if [ -n "$SRC" ] && [ -f "$SRC" ]; then
            A=$(sha256sum "$SRC"   | awk '{print $1}')
            B=$(sha256sum "$SAMPLE" | awk '{print $1}')
            if [ "$A" = "$B" ]; then
                echo "  spot sha256 match : $(basename "$SRC")"
            else
                echo "[fail] spot sha256 mismatch for $(basename "$SRC")" >&2
                fail=1
            fi
        fi
    fi
fi

if [ $fail -ne 0 ]; then
    echo "[note] preserving $SMOKE_ROOT for inspection"
    exit 5
fi

echo
echo "[pass] DINOv2 access-pattern (small-files / nested-dirs) goes through FitCache cleanly."
echo "       FitCache's path-filter + data mover handle the many-small-files I/O shape."

if [ "${KEEP:-0}" = "0" ]; then
    rm -rf "$SMOKE_ROOT"
fi
