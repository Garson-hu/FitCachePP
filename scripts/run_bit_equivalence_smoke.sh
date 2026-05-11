#!/usr/bin/env bash
#
# run_bit_equivalence_smoke.sh
#
# Defends the zero-regression-vs-IPDPS-single-job claim at the bit level.
#
# Method:
#   1. Build a small synthetic dataset (8 files of ~256 KiB each).
#   2. Run a single fitcache_server in IPDPS mode (FitCache_CROSS_JOB=0).
#      Drive it with tests/harness_read_files (the LD_PRELOAD client) so
#      every file gets opened, read end-to-end, and promoted into the
#      cache tier. Snapshot sha256 of every cached file.
#   3. Tear down server + cache, repeat with FitCache_CROSS_JOB=1 (so the
#      cluster registry + HRW routing path is exercised) but with one
#      server only (so no peer-lookup fanout fires). Snapshot sha256 again.
#   4. Assert: per-file sha256 must match between Pass A and Pass B, and
#      both must match the source files. (Bit-for-bit cache content is the
#      strongest single-process check that the cross-job code path
#      preserves data correctness when run in single-job degenerate mode.)
#
# Notes:
#   - We compare *cached* file contents, not just client read results.
#     The point is to guarantee the on-disk layout is identical, so the
#     cross-job restart pathway reads the same bytes regardless of which
#     mode wrote them.
#   - We do NOT compare path_cache_map state (the in-memory map differs by
#     design: with CROSS_JOB=1 the server populates dataset_id and
#     subscriber lease records, which are absent in CROSS_JOB=0).

set -u
set -o pipefail

REPO=/home/ghu4/hvac/FitCachePP
SERVER_BIN=$REPO/build/src/fitcache_server
CLIENT_LIB=$REPO/build/src/libfitcache_client.so
HARNESS_BIN=$REPO/build/tests/harness_read_files

for f in "$SERVER_BIN" "$CLIENT_LIB" "$HARNESS_BIN"; do
    [ -f "$f" ] || { echo "missing build artifact: $f" >&2; exit 2; }
done

# Mercury / log4c env (matches build/build.sh and run_two_server_smoke.sh).
export PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH

SMOKE_ROOT=/tmp/fitcachepp_bit_equiv_$$
mkdir -p "$SMOKE_ROOT"/{dataset,registry,cache_off_dram,cache_off_nvme,cache_on_dram,cache_on_nvme,logs,cwd}
echo "[setup] smoke root: $SMOKE_ROOT"

# Deterministic synthetic dataset: 8 files, 256 KiB each. Content is
# pid-derived but stays stable for the lifetime of this script.
for i in 0 1 2 3 4 5 6 7; do
    head -c $((256 * 1024)) /dev/urandom > "$SMOKE_ROOT/dataset/file_$i.bin"
done
SRC_HASHES=$(cd "$SMOKE_ROOT/dataset" && sha256sum file_*.bin | sort -k2)
echo "[setup] source hashes:"
echo "$SRC_HASHES" | sed 's/^/  /'

# CWD must exist before server starts (.ports.cfg gets dropped here).
cd "$SMOKE_ROOT/cwd"

export FitCache_DATA_DIR=$SMOKE_ROOT/dataset
export FitCache_CLUSTER_REGISTRY_DIR=$SMOKE_ROOT/registry
export FitCache_HEARTBEAT_SEC=5
export FitCache_LOG_LEVEL=700
export FitCache_SERVER_COUNT=1

run_pass() {
    local label=$1
    local cross_job=$2
    local dram=$3
    local nvme=$4

    echo
    echo "=== pass: $label (FitCache_CROSS_JOB=$cross_job) ==="

    # Clean registry + cache between passes.
    rm -rf "$SMOKE_ROOT/registry"/*
    mkdir -p "$SMOKE_ROOT/registry"
    rm -rf "$dram"/* "$nvme"/*
    # Wipe any per-job ports cfg from the previous run.
    rm -f "$SMOKE_ROOT/cwd"/*.ports.cfg "$SMOKE_ROOT/cwd"/.ports.cfg

    local server_log=$SMOKE_ROOT/logs/server_${label}.log
    local client_log=$SMOKE_ROOT/logs/client_${label}.log

    FitCache_CROSS_JOB=$cross_job \
    SLURM_JOBID=1001 SLURM_PROCID=0 \
    FitCache_DRAM_PATH=$dram \
    FitCache_NVME_PATH=$nvme \
    FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024)) \
    FitCache_NVME_CAPACITY=$((512 * 1024 * 1024)) \
    "$SERVER_BIN" 1 > "$server_log" 2>&1 &
    local sid=$!

    # Wait up to ~10s for the server to publish its endpoint.
    for i in $(seq 1 20); do
        if [ -s "$SMOKE_ROOT/cwd/.ports.cfg" ] || ls "$SMOKE_ROOT/cwd"/*.ports.cfg >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done

    if ! kill -0 "$sid" 2>/dev/null; then
        echo "[fatal] server died at startup; tail of $server_log:" >&2
        tail -60 "$server_log" >&2
        return 3
    fi

    FitCache_CROSS_JOB=$cross_job \
    SLURM_JOBID=1001 SLURM_PROCID=0 \
    FitCache_DRAM_PATH=$dram \
    FitCache_NVME_PATH=$nvme \
    FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024)) \
    FitCache_NVME_CAPACITY=$((512 * 1024 * 1024)) \
    LD_PRELOAD=$CLIENT_LIB \
    "$HARNESS_BIN" "$SMOKE_ROOT/dataset" > "$client_log" 2>&1
    local rc=$?

    # Let the data mover finish promotion (close -> fs::copy is async).
    sleep 3

    kill -TERM "$sid" 2>/dev/null || true
    sleep 1
    kill -9 "$sid" 2>/dev/null || true
    wait "$sid" 2>/dev/null || true

    if [ $rc -ne 0 ]; then
        echo "[fatal] harness exited rc=$rc; tail of $client_log:" >&2
        tail -40 "$client_log" >&2
        return 4
    fi

    echo "[pass:$label] cached files (DRAM):"
    (cd "$dram" 2>/dev/null && find . -type f 2>/dev/null | sort | head -20 | sed 's/^/  /')
    echo "[pass:$label] cached files (NVME):"
    (cd "$nvme" 2>/dev/null && find . -type f 2>/dev/null | sort | head -20 | sed 's/^/  /')
}

run_pass off 0 "$SMOKE_ROOT/cache_off_dram" "$SMOKE_ROOT/cache_off_nvme" || exit $?
run_pass on  1 "$SMOKE_ROOT/cache_on_dram"  "$SMOKE_ROOT/cache_on_nvme"  || exit $?

# Hashes of *cached payloads* must match the source. Cache layout is keyed
# by basename; the server stores promoted files under their original name
# in the chosen tier directory.
hash_cache() {
    local dram=$1
    local nvme=$2
    {
        [ -d "$dram" ] && (cd "$dram" && find . -type f -name 'file_*.bin' -exec sha256sum {} +)
        [ -d "$nvme" ] && (cd "$nvme" && find . -type f -name 'file_*.bin' -exec sha256sum {} +)
    } 2>/dev/null | awk '{ n=split($2,a,"/"); print $1, a[n] }' | sort -k2
}

H_A=$(hash_cache "$SMOKE_ROOT/cache_off_dram" "$SMOKE_ROOT/cache_off_nvme")
H_B=$(hash_cache "$SMOKE_ROOT/cache_on_dram"  "$SMOKE_ROOT/cache_on_nvme")
H_SRC=$(echo "$SRC_HASHES" | awk '{print $1, $2}' | sort -k2)

echo
echo "=== bit-equivalence comparison ==="
echo "[source]"
echo "$H_SRC" | sed 's/^/  /'
echo "[cached: cross_job=off]"
echo "$H_A" | sed 's/^/  /'
echo "[cached: cross_job=on (single-server)]"
echo "$H_B" | sed 's/^/  /'

rc=0
if [ -z "$H_A" ]; then
    echo "[fail] cross_job=off produced no cached files" >&2; rc=5
elif [ "$H_A" != "$H_SRC" ]; then
    echo "[fail] cross_job=off cache does NOT match source" >&2; rc=6
fi
if [ -z "$H_B" ]; then
    echo "[fail] cross_job=on produced no cached files" >&2; rc=7
elif [ "$H_B" != "$H_SRC" ]; then
    echo "[fail] cross_job=on cache does NOT match source" >&2; rc=8
fi
if [ "$H_A" != "$H_B" ]; then
    echo "[fail] cross_job=off and cross_job=on caches differ from each other" >&2
    rc=9
fi

if [ $rc -eq 0 ]; then
    echo
    echo "[pass] bit-equivalence holds: cross_job={off,on} caches identical to source."
    echo "[pass] zero-regression-vs-IPDPS-single-job claim defended at the byte level."
fi

if [ "${KEEP:-0}" = "0" ] && [ $rc -eq 0 ]; then
    rm -rf "$SMOKE_ROOT"
else
    echo "[note] preserved $SMOKE_ROOT for inspection"
fi

exit $rc
