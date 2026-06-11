#!/usr/bin/env bash
#
# p1b_overhead_bench.sh (v2) — P1-b overhead + traffic-accounting microbench.
# One Frontier node (-C nvme). v2 fixes over the 4788746 run:
#   - all logs + cwds live under RESULTS_DIR on Lustre (survive walltime kill)
#   - one fresh cwd per phase (fresh .ports.cfg; the v1 server restarts in a
#     shared cwd produced zero promotions in phases B/C)
#   - phase B slimmed to 2 x 1.5 GiB read with a 16 MiB buffer harness
#   - tier-population wait loops instead of fixed sleeps
#   - page-cache evict before EVERY measured pass
#
# Phases:
#   A. syscall-path latency, 256 x 4 MiB: native vs cold vs warm (x3)
#   B. traffic counters, 2 x 1.5 GiB: bytes_winner / bytes_redundant /
#      fetch_rpcs_issued on a warm RPC pass
#   C. mmap path: native vs warm-hit (mmap.resolve_us / warmhit_total_us)
#   D. pass-through: LD_PRELOAD on, dataset untracked
set -u
set -o pipefail

REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP
SERVER_BIN=$REPO/build/src/fitcache_server
CLIENT_LIB=$REPO/build/src/libfitcache_client.so
HARNESS_READ=$REPO/build/tests/harness_read_files
EVICT=$REPO/scripts/legacy/evict_page_cache.py

RESULTS_DIR=${RESULTS_DIR:-$REPO/benchmarks/results/frontier/p1b_overhead_${SLURM_JOBID:-local}}
DATASET_SMALL=/lustre/orion/gen008/proj-shared/ghu4/p1b_data/small
DATASET_LARGE=/lustre/orion/gen008/proj-shared/ghu4/p1b_data/large2   # 2 files
DRAM_PATH=/tmp/p1b_dram_$$
NVME_PATH=/mnt/bb/$USER/p1b_nvme_$$

LOGS=$RESULTS_DIR/logs
mkdir -p "$LOGS" "$DRAM_PATH" "$NVME_PATH"
exec > >(tee "$RESULTS_DIR/bench.log") 2>&1
echo "[setup] node=$(hostname) job=${SLURM_JOBID:-none} date=$(date -Is)"

for f in "$SERVER_BIN" "$CLIENT_LIB" "$HARNESS_READ" "$EVICT"; do
    [ -e "$f" ] || { echo "[fatal] missing: $f"; exit 2; }
done

HARNESS_MMAP=$RESULTS_DIR/harness_mmap_files.bin
HARNESS_PREAD=$RESULTS_DIR/harness_pread.bin
gcc -O2 -o "$HARNESS_MMAP"  "$REPO/scripts/p1b/harness_mmap_files.c" || exit 2
gcc -O2 -o "$HARNESS_PREAD" "$REPO/scripts/p1b/harness_pread.c"      || exit 2

# large2 dataset: 2 x 1.5 GiB (generate if absent)
mkdir -p "$DATASET_LARGE"
if [ "$(find "$DATASET_LARGE" -maxdepth 1 -name 'file_*.bin' | wc -l)" -ne 2 ]; then
    echo "[setup] generating 2 x 1.5 GiB in $DATASET_LARGE"
    rm -f "$DATASET_LARGE"/file_*.bin
    for i in 0 1; do
        head -c $((1536 * 1024 * 1024)) /dev/urandom > "$DATASET_LARGE/file_000$i.bin"
    done
fi

evict() { python3 "$EVICT" "$1" >/dev/null 2>&1 || echo "[warn] evict failed for $1"; }

export FitCache_LOG_LEVEL=600
export FitCache_SERVER_COUNT=1
export FitCache_DRAM_PATH=$DRAM_PATH
export FitCache_NVME_PATH=$NVME_PATH
export FitCache_DRAM_CAPACITY=$((2 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((20 * 1024 * 1024 * 1024))
export FitCache_CROSS_JOB=0
export FITPP_TIMING_DUMP_ON_EXIT=1
export SLURM_PROCID=0

SID=""
start_server() { # phase-label
    local cwd=$LOGS/cwd_$1
    mkdir -p "$cwd"
    cd "$cwd"
    "$SERVER_BIN" 1 > "$LOGS/server_$1.log" 2>&1 &
    SID=$!
    sleep 3
    kill -0 "$SID" 2>/dev/null || { echo "[fatal] server died ($1)"; tail -30 "$LOGS/server_$1.log"; exit 3; }
    ls .ports.cfg.* >/dev/null 2>&1 && echo "[setup] server $1 up, ports file present" \
        || echo "[warn] server $1: no ports file in $cwd"
}
stop_server() {
    [ -n "$SID" ] || return 0
    kill -TERM "$SID" 2>/dev/null || true; sleep 2
    kill -9 "$SID" 2>/dev/null || true; wait "$SID" 2>/dev/null || true
    SID=""
}
wait_promotion() { # expected-count timeout-sec
    local want=$1 tmo=$2 t=0 n=0
    while [ $t -lt "$tmo" ]; do
        n=$(( $(find "$DRAM_PATH" -type f 2>/dev/null | grep -vc '\.meta$') + $(find "$NVME_PATH" -type f 2>/dev/null | grep -vc '\.meta$') ))
        [ "$n" -ge "$want" ] && break
        sleep 5; t=$((t + 5))
    done
    echo "[check] tier population after ${t}s: total=$n (want $want) dram=$(find $DRAM_PATH -type f | grep -vc '\.meta$') nvme=$(find $NVME_PATH -type f | grep -vc '\.meta$')"
}
timed() { # label log cmd...
    local label=$1 log=$2; shift 2
    local t0 t1 rc
    t0=$(date +%s.%N)
    "$@" > "$log" 2>&1
    rc=$?
    t1=$(date +%s.%N)
    echo "[timing] $label wall=$(awk "BEGIN{print $t1-$t0}")s rc=$rc"
}
show_tags() { # log
    grep -A24 "FitCache timing summary" "$1" | head -28
}

echo
echo "########## Phase A: syscall path, small files ##########"
evict "$DATASET_SMALL"
timed "A.native" "$LOGS/a_native.log" "$HARNESS_PREAD" "$DATASET_SMALL" 1048576
start_server A
evict "$DATASET_SMALL"
timed "A.fitpp_cold" "$LOGS/a_cold.log" env FitCache_DATA_DIR=$DATASET_SMALL LD_PRELOAD=$CLIENT_LIB "$HARNESS_PREAD" "$DATASET_SMALL" 1048576
wait_promotion 256 90
for r in 1 2 3; do
    evict "$DATASET_SMALL"
    timed "A.fitpp_warm_$r" "$LOGS/a_warm_$r.log" env FitCache_DATA_DIR=$DATASET_SMALL LD_PRELOAD=$CLIENT_LIB "$HARNESS_PREAD" "$DATASET_SMALL" 1048576
done
echo "--- tags: cold ---";   show_tags "$LOGS/a_cold.log"
echo "--- tags: warm_3 ---"; show_tags "$LOGS/a_warm_3.log"
stop_server

echo
echo "########## Phase B: traffic accounting, 2 x 1.5 GiB ##########"
rm -rf "$DRAM_PATH"/* "$NVME_PATH"/*
start_server B
evict "$DATASET_LARGE"
timed "B.fitpp_cold" "$LOGS/b_cold.log" env FitCache_DATA_DIR=$DATASET_LARGE LD_PRELOAD=$CLIENT_LIB "$HARNESS_PREAD" "$DATASET_LARGE" 16777216
wait_promotion 2 120
evict "$DATASET_LARGE"
timed "B.fitpp_warm" "$LOGS/b_warm.log" env FitCache_DATA_DIR=$DATASET_LARGE LD_PRELOAD=$CLIENT_LIB "$HARNESS_PREAD" "$DATASET_LARGE" 16777216
echo "--- tags: warm (traffic counters) ---"; show_tags "$LOGS/b_warm.log"
grep "harness_pread" "$LOGS/b_warm.log" || true
stop_server

echo
echo "########## Phase C: mmap path ##########"
rm -rf "$DRAM_PATH"/* "$NVME_PATH"/*
start_server C
evict "$DATASET_SMALL"
timed "C.prewarm_read" "$LOGS/c_prewarm.log" env FitCache_DATA_DIR=$DATASET_SMALL LD_PRELOAD=$CLIENT_LIB "$HARNESS_READ" "$DATASET_SMALL"
wait_promotion 256 90
evict "$DATASET_SMALL"
timed "C.mmap_native" "$LOGS/c_native.log" "$HARNESS_MMAP" "$DATASET_SMALL"
grep "mmap-harness" "$LOGS/c_native.log"
evict "$DATASET_SMALL"
timed "C.mmap_fitpp_warm" "$LOGS/c_warm.log" env FitCache_DATA_DIR=$DATASET_SMALL LD_PRELOAD=$CLIENT_LIB "$HARNESS_MMAP" "$DATASET_SMALL"
grep "mmap-harness" "$LOGS/c_warm.log"
echo "--- tags: mmap warm ---"; show_tags "$LOGS/c_warm.log"
stop_server

echo
echo "########## Phase D: pass-through ##########"
start_server D
evict "$DATASET_SMALL"
timed "D.native"      "$LOGS/d_native.log" "$HARNESS_PREAD" "$DATASET_SMALL" 1048576
evict "$DATASET_SMALL"
timed "D.passthrough" "$LOGS/d_pass.log" env FitCache_DATA_DIR=/nonexistent_p1b LD_PRELOAD=$CLIENT_LIB "$HARNESS_PREAD" "$DATASET_SMALL" 1048576
echo "--- tags: passthrough ---"; show_tags "$LOGS/d_pass.log"
stop_server

rm -rf "$DRAM_PATH" "$NVME_PATH"
echo "[done] $(date -Is) results in $RESULTS_DIR"
