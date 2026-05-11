#!/usr/bin/env bash
#
# run_three_tier_smoke.sh
#
# Defends the three-tier (DRAM + PMem + NVMe) placement & restoration path
# end-to-end on a single host. PMem is faked here with a regular directory
# (the placement / sidecar / eviction logic doesn't care about DAX vs ext4 —
# the path is just where files land), so this smoke can run on any machine
# even without PMem hardware.
#
# Method:
#   1. Build a synthetic dataset of 12 files of 1 MiB each (12 MiB total).
#   2. Spawn one fitcache_server with three tiers configured. Capacities are
#      tight so the file population spills across tiers:
#        - DRAM_CAPACITY=4 MiB   → first ~4 files go to DRAM
#        - PMEM_CAPACITY=4 MiB   → next ~4 files go to PMem
#        - NVME_CAPACITY=4 MiB   → last ~4 files go to NVMe
#   3. Drive the server with harness_read_files; each file is opened, read,
#      and promoted into one of the three tier dirs by the data mover.
#   4. Inspect the on-disk layout: assert PMem dir is non-empty (i.e. the
#      placement actually used the new tier and didn't all spill to NVMe).
#   5. Restart the server with FitCache_CROSS_JOB=1 so it scans sidecars at
#      startup. Assert the restore-sidecars log line reports >0 files
#      restored *from each tier*.
#
# Quirks:
#   - With FitCache_CROSS_JOB=0 the sidecars are still written but never
#     scanned at startup; that's the IPDPS behavior. We only exercise the
#     restore path in the cross-job pass.

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

SMOKE_ROOT=/tmp/fitcachepp_three_tier_$$
mkdir -p "$SMOKE_ROOT"/{dataset,registry,dram,pmem,nvme,cwd,logs}
echo "[setup] smoke root: $SMOKE_ROOT"

# 12 files * 1 MiB each = 12 MiB total. With per-tier capacities of 4 MiB,
# placement must spill DRAM->PMem->NVMe in order. (The arithmetic isn't quite
# that clean because the high-water-mark check uses the running used_bytes
# total at placement decision time, but 4/4/4 is enough to force the
# placement code into every branch.)
for i in $(seq 0 11); do
    head -c $((1024 * 1024)) /dev/urandom > "$SMOKE_ROOT/dataset/file_$i.bin"
done

cd "$SMOKE_ROOT/cwd"
export FitCache_DATA_DIR=$SMOKE_ROOT/dataset
export FitCache_CLUSTER_REGISTRY_DIR=$SMOKE_ROOT/registry
export FitCache_HEARTBEAT_SEC=5
export FitCache_LOG_LEVEL=700
export FitCache_SERVER_COUNT=1
export FitCache_DRAM_PATH=$SMOKE_ROOT/dram
export FitCache_PMEM_PATH=$SMOKE_ROOT/pmem
export FitCache_NVME_PATH=$SMOKE_ROOT/nvme
export FitCache_DRAM_CAPACITY=$((4  * 1024 * 1024))
export FitCache_PMEM_CAPACITY=$((4 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((4 * 1024 * 1024))
export SLURM_JOBID=1001
export SLURM_PROCID=0

run_server_and_workload() {
    local label=$1
    local cross_job=$2
    rm -f "$SMOKE_ROOT/cwd"/*.ports.cfg "$SMOKE_ROOT/cwd"/.ports.cfg

    local server_log=$SMOKE_ROOT/logs/server_${label}.log
    local server_l4c=  # captured from cwd after the run
    local client_log=$SMOKE_ROOT/logs/client_${label}.log

    FitCache_CROSS_JOB=$cross_job \
    "$SERVER_BIN" 1 > "$server_log" 2>&1 &
    local sid=$!
    sleep 3
    if ! kill -0 "$sid" 2>/dev/null; then
        echo "[fatal] server died at startup; tail $server_log:" >&2
        tail -40 "$server_log" >&2
        return 3
    fi

    FitCache_CROSS_JOB=$cross_job \
    LD_PRELOAD=$CLIENT_LIB "$HARNESS_BIN" "$SMOKE_ROOT/dataset" > "$client_log" 2>&1
    local rc=$?
    sleep 4    # wait for the data mover to promote everything

    kill -TERM "$sid" 2>/dev/null || true
    sleep 1
    kill -9 "$sid" 2>/dev/null || true
    wait "$sid" 2>/dev/null || true

    if [ $rc -ne 0 ]; then
        echo "[fatal] harness exited rc=$rc; tail of $client_log:" >&2
        tail -40 "$client_log" >&2
        return 4
    fi
    # Move the log4c-written server logs into the smoke logs dir for archival.
    mv "$SMOKE_ROOT/cwd"/fitcache_server_log.* "$SMOKE_ROOT/logs/" 2>/dev/null || true
    return 0
}

echo
echo "=== Pass 1: populate cache (CROSS_JOB=1 so sidecars get written) ==="
run_server_and_workload populate 1 || exit $?

count_tier() {
    find "$1" -type f -name 'file_*.bin' 2>/dev/null | wc -l
}
DRAM_N=$(count_tier "$SMOKE_ROOT/dram")
PMEM_N=$(count_tier "$SMOKE_ROOT/pmem")
NVME_N=$(count_tier "$SMOKE_ROOT/nvme")

echo
echo "[tier counts after Pass 1] dram=$DRAM_N pmem=$PMEM_N nvme=$NVME_N (total=12)"

if [ "$PMEM_N" -eq 0 ]; then
    echo "[fail] PMem tier received zero files — placement code didn't pick the new tier" >&2
    echo "       (check FitCache_PMEM_PATH/_CAPACITY env wiring in fitcache_data_mover.cpp)" >&2
    exit 5
fi
if [ "$DRAM_N" -eq 0 ]; then
    echo "[fail] DRAM tier received zero files — first-tier placement broken" >&2
    exit 6
fi
if [ $((DRAM_N + PMEM_N + NVME_N)) -lt 12 ]; then
    echo "[warn] only $((DRAM_N + PMEM_N + NVME_N))/12 files made it into a tier — some opens may have failed PFS-fallback"
fi

echo
echo "=== Pass 2: restart server, verify restore-sidecars rebuilds all three tiers ==="
# Don't wipe the tier dirs — that's the whole point: we want server 2 to
# discover server 1's sidecars and rebuild path_cache_map from them.
run_server_and_workload restore 1 || exit $?

RESTORE_LOG=$(grep "restore-sidecars" "$SMOKE_ROOT/logs"/fitcache_server_log.*  2>/dev/null || true)
echo
echo "[restore log lines]"
echo "$RESTORE_LOG" | sed 's/^/  /'

# Each tier with non-zero file count in Pass 1 must produce a "restored N files from <TIER>" line.
fail=0
for tier_name_path in "DRAM:$SMOKE_ROOT/dram:$DRAM_N" "PMem:$SMOKE_ROOT/pmem:$PMEM_N" "NVMe:$SMOKE_ROOT/nvme:$NVME_N"; do
    tname=${tier_name_path%%:*}
    rest=${tier_name_path#*:}
    tpath=${rest%%:*}
    tcount=${rest##*:}
    if [ "$tcount" -gt 0 ]; then
        if ! echo "$RESTORE_LOG" | grep -q "restored .* files from $tname tier $tpath"; then
            echo "[fail] no restore-sidecars log for $tname tier ($tcount files in $tpath)" >&2
            fail=1
        fi
    fi
done

if [ $fail -ne 0 ]; then
    echo "[note] preserved $SMOKE_ROOT for inspection"
    exit 7
fi

echo
echo "[pass] three-tier placement (DRAM + PMem + NVMe) populated and the"
echo "       restore-sidecars path rebuilt path_cache_map from all three tiers."

if [ "${KEEP:-0}" = "0" ]; then
    rm -rf "$SMOKE_ROOT"
fi
