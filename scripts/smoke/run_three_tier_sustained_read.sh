#!/usr/bin/env bash
#
# run_three_tier_sustained_read.sh
#
# Three-tier (DRAM + PMem + NVMe) sustained-read micro-benchmark.
# Designed to run anywhere (no GPU dependency, no TensorFlow), so we can
# exercise the three-tier path on the PMem-equipped node (e.g. c35 in the
# cascade partition) even without an ML toolchain.
#
# Method:
#   - 256 files of 4 MiB each = 1 GiB working set.
#   - DRAM/PMem/NVMe capacities of 200/400/600 MiB. Some files spill into
#     each tier, exercising placement priority and (with the workload
#     larger than the sum of tiers) eviction.
#   - Warm-up pass: read every file once. Times this pass — that's the
#     "cold + populate" cost.
#   - Steady-state pass: read every file 4 more times in random order.
#     Times this pass — that's the "warm cache hits" cost.
#   - Compare the two means and emit a one-line summary.
#
# The point: characterise the cold/warm gap on real PMem hardware, and
# verify per-tier placement happens under a sustained read workload (the
# data mover queue actually drains fast enough that subsequent reads hit
# the cache).

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

# Optional: caller can pin paths into real PMem / NVMe locations.
DRAM_PATH=${DRAM_PATH:-/tmp/fitcachepp_sr_dram_$$}
PMEM_PATH=${PMEM_PATH:-/tmp/fitcachepp_sr_pmem_$$}
NVME_PATH=${NVME_PATH:-/tmp/fitcachepp_sr_nvme_$$}

SR_ROOT=/tmp/fitcachepp_sustained_read_$$
mkdir -p "$SR_ROOT"/{registry,cwd,logs}
mkdir -p "$DRAM_PATH" "$PMEM_PATH" "$NVME_PATH"

# DATASET_DIR: optional override. When set, place the dataset there (e.g. a
# BeeGFS path) instead of under /tmp. The smoke's measured "cold pass" only
# stresses the cache-vs-source ratio if the source is on slow storage and
# the source files are not already in the OS page cache (we evict below).
# When DATASET_DIR is unset, fall back to /tmp behaviour for portability.
DATASET_DIR=${DATASET_DIR:-$SR_ROOT/dataset}
mkdir -p "$DATASET_DIR"
DATASET_PERSISTENT=1
if [ "$DATASET_DIR" = "$SR_ROOT/dataset" ]; then
    DATASET_PERSISTENT=0
fi

echo "[setup] root: $SR_ROOT"
echo "[setup] DRAM: $DRAM_PATH"
echo "[setup] PMem: $PMEM_PATH"
echo "[setup] NVMe: $NVME_PATH"
echo "[setup] dataset: $DATASET_DIR (persistent=$DATASET_PERSISTENT)"

# 256 files * 4 MiB
N_FILES=${N_FILES:-256}
FILE_SIZE_MIB=${FILE_SIZE_MIB:-4}
# Reuse existing dataset if it has the expected file count + sizes, so a
# DATASET_DIR pinned to BeeGFS doesn't have to regenerate 1 GiB of urandom
# on every smoke run.
EXISTING_COUNT=$(find "$DATASET_DIR" -maxdepth 1 -type f -name 'file_*.bin' 2>/dev/null | wc -l)
if [ "$EXISTING_COUNT" -eq "$N_FILES" ]; then
    echo "[setup] reusing existing dataset at $DATASET_DIR ($N_FILES files)"
else
    echo "[setup] generating dataset at $DATASET_DIR ($N_FILES files of $FILE_SIZE_MIB MiB)"
    for i in $(seq 0 $((N_FILES - 1))); do
        head -c $((FILE_SIZE_MIB * 1024 * 1024)) /dev/urandom > "$DATASET_DIR/file_$(printf %04d $i).bin"
    done
fi
echo "[setup] dataset total: $((N_FILES * FILE_SIZE_MIB)) MiB"

# Drop the OS page cache for the dataset before the warm-up pass so the
# warm-up actually pays disk/PFS read cost. Without this, a previous run
# (or the dataset-generation `head -c` above) leaves the source files
# fully in RAM and both passes get RAM-speed source reads, hiding any
# cache-vs-source difference. evict_page_cache.py uses
# posix_fadvise(POSIX_FADV_DONTNEED) — no sudo required.
echo "[setup] evicting source dataset from OS page cache before warm-up"
python3 "$REPO/scripts/evict_page_cache.py" "$DATASET_DIR" 2>&1 | sed 's/^/  /'

cd "$SR_ROOT/cwd"
export FitCache_DATA_DIR=$DATASET_DIR
export FitCache_CLUSTER_REGISTRY_DIR=$SR_ROOT/registry
export FitCache_HEARTBEAT_SEC=10
export FitCache_LOG_LEVEL=500
export FitCache_SERVER_COUNT=1
export FitCache_DRAM_PATH=$DRAM_PATH
export FitCache_PMEM_PATH=$PMEM_PATH
export FitCache_NVME_PATH=$NVME_PATH
export FitCache_DRAM_CAPACITY=$((200 * 1024 * 1024))
export FitCache_PMEM_CAPACITY=$((400 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((600 * 1024 * 1024))
export FitCache_CROSS_JOB=1   # enable cross-job (== enables PMem tier wiring)
export SLURM_JOBID=${SLURM_JOBID:-9999}
export SLURM_PROCID=0

"$SERVER_BIN" 1 > "$SR_ROOT/logs/server.log" 2>&1 &
SID=$!
sleep 3
if ! kill -0 "$SID" 2>/dev/null; then
    echo "[fatal] server died at startup; tail $SR_ROOT/logs/server.log:" >&2
    tail -40 "$SR_ROOT/logs/server.log" >&2
    exit 3
fi

echo
echo "=== Warm-up pass (populate cache) ==="
T0=$(date +%s.%N)
LD_PRELOAD=$CLIENT_LIB "$HARNESS_BIN" "$DATASET_DIR" > "$SR_ROOT/logs/client_warmup.log" 2>&1
RC=$?
T1=$(date +%s.%N)
WARMUP_S=$(awk "BEGIN { print $T1 - $T0 }")
echo "[result] warm-up pass: ${WARMUP_S}s (rc=$RC)"
if [ $RC -ne 0 ]; then
    echo "[fatal] harness rc=$RC; tail of client_warmup.log:" >&2
    tail -20 "$SR_ROOT/logs/client_warmup.log" >&2
    kill -9 "$SID" 2>/dev/null
    exit 4
fi

# Let the data mover finish promoting whatever's queued.
sleep 5

# Snapshot per-tier file counts after warm-up.
count_tier() { find "$1" -type f -name 'file_*.bin' 2>/dev/null | wc -l; }
DRAM_N=$(count_tier "$DRAM_PATH")
PMEM_N=$(count_tier "$PMEM_PATH")
NVME_N=$(count_tier "$NVME_PATH")
echo "[result] tier population: dram=$DRAM_N pmem=$PMEM_N nvme=$NVME_N (target=$N_FILES)"

# Evict the source dataset from OS page cache again before steady-state.
# Otherwise the warm-up just left a full copy of the dataset in RAM and
# steady-state reads would hit page cache regardless of which tier they
# resolve to — so we can't measure cache-vs-source. Note: tier files in
# DRAM_PATH/PMEM_PATH/NVME_PATH are kept hot intentionally (those ARE the
# cache). Only the source is evicted.
echo "[setup] evicting source dataset from OS page cache before steady-state"
python3 "$REPO/scripts/evict_page_cache.py" "$DATASET_DIR" 2>&1 | sed 's/^/  /'

echo
echo "=== Steady-state pass (4x re-reads, mostly warm hits) ==="
T0=$(date +%s.%N)
for round in 1 2 3 4; do
    LD_PRELOAD=$CLIENT_LIB "$HARNESS_BIN" "$DATASET_DIR" > "$SR_ROOT/logs/client_steady_$round.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "[fatal] steady round $round failed" >&2
        kill -9 "$SID" 2>/dev/null
        exit 5
    fi
done
T1=$(date +%s.%N)
STEADY_S=$(awk "BEGIN { print $T1 - $T0 }")
STEADY_MEAN_S=$(awk "BEGIN { print $STEADY_S / 4 }")
echo "[result] steady-state total: ${STEADY_S}s for 4 rounds; mean/round=${STEADY_MEAN_S}s"

# Final cross-job counters via SIGTERM (which triggers log_cross_job_stats).
kill -TERM "$SID" 2>/dev/null || true
sleep 2
kill -9 "$SID" 2>/dev/null || true
wait "$SID" 2>/dev/null || true
# Move log4c log next to the others for archival.
mv "$SR_ROOT/cwd"/fitcache_server_log.* "$SR_ROOT/logs/" 2>/dev/null || true

echo
echo "=== Cross-job counters at shutdown ==="
grep "cross_job_stats" "$SR_ROOT/logs"/fitcache_server_log.* 2>/dev/null | tail -3 | sed 's/^/  /'

echo
echo "=== Summary ==="
RATIO=$(awk "BEGIN { if ($STEADY_MEAN_S > 0) print $WARMUP_S / $STEADY_MEAN_S; else print 0 }")
echo "  warm-up (1 cold pass): ${WARMUP_S}s"
echo "  steady (1 warm pass):  ${STEADY_MEAN_S}s"
echo "  speedup (warm vs cold): ${RATIO}x"
echo "  tier distribution:     dram=$DRAM_N pmem=$PMEM_N nvme=$NVME_N"

if [ "${KEEP:-0}" = "0" ]; then
    rm -rf "$SR_ROOT" "$DRAM_PATH" "$PMEM_PATH" "$NVME_PATH"
    if [ "$DATASET_PERSISTENT" = "0" ]; then
        rm -rf "$DATASET_DIR"
    else
        echo "[cleanup] keeping persistent dataset at $DATASET_DIR"
    fi
fi
