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
mkdir -p "$SR_ROOT"/{dataset,registry,cwd,logs}
mkdir -p "$DRAM_PATH" "$PMEM_PATH" "$NVME_PATH"
echo "[setup] root: $SR_ROOT"
echo "[setup] DRAM: $DRAM_PATH"
echo "[setup] PMem: $PMEM_PATH"
echo "[setup] NVMe: $NVME_PATH"

# 256 files * 4 MiB
N_FILES=${N_FILES:-256}
FILE_SIZE_MIB=${FILE_SIZE_MIB:-4}
for i in $(seq 0 $((N_FILES - 1))); do
    head -c $((FILE_SIZE_MIB * 1024 * 1024)) /dev/urandom > "$SR_ROOT/dataset/file_$(printf %04d $i).bin"
done
echo "[setup] generated $N_FILES files of $FILE_SIZE_MIB MiB each = $((N_FILES * FILE_SIZE_MIB)) MiB total"

cd "$SR_ROOT/cwd"
export FitCache_DATA_DIR=$SR_ROOT/dataset
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
LD_PRELOAD=$CLIENT_LIB "$HARNESS_BIN" "$SR_ROOT/dataset" > "$SR_ROOT/logs/client_warmup.log" 2>&1
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

echo
echo "=== Steady-state pass (4x re-reads, mostly warm hits) ==="
T0=$(date +%s.%N)
for round in 1 2 3 4; do
    LD_PRELOAD=$CLIENT_LIB "$HARNESS_BIN" "$SR_ROOT/dataset" > "$SR_ROOT/logs/client_steady_$round.log" 2>&1
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
fi
