#!/bin/bash
#
# run_migrate_localhost_smoke.sh
#
# Localhost validation of the peer->local MIGRATION primitive (TPDS), on real
# Mercury bulk, with no SLURM allocation. Isolates the migrate primitive from
# the prefetch client + node_local routing by driving it through the server-side
# self-test hook (FitCache_MIGRATE_SELFTEST).
#
# Flow:
#   1. Synthetic dataset: a few files, file_0 sized to exercise a real bulk RMA.
#   2. Start S1 (jobid 1001) and S2 (jobid 1002), both FitCache_CROSS_JOB=1 with a
#      shared registry. S2 also gets FitCache_MIGRATE_SELFTEST=<file_0> -> its
#      self-test thread polls remote_presence_lookup(file_0) and, once a peer
#      announces it, calls fitcache_server_migrate_file to pull it peer->local.
#   3. Wait for both servers live in the registry.
#   4. Client A (jobid 1001) reads the dataset through S1 -> S1 caches each file
#      at close time and BROADCASTS presence to live peers (S2 included).
#   5. S2's self-test sees file_0's presence -> migrates it from S1 into cache2.
#   6. Verify file_0 lands at S2's tier hash-bin path with byte-identical content.
#
# Exit 0 iff the migrated copy exists in S2's cache and matches the source bytes.

set -u
set -o pipefail

REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP
SERVER_BIN=$REPO/build/src/fitcache_server
CLIENT_LIB=$REPO/build/src/libfitcache_client.so
HARNESS_BIN=$REPO/build/tests/harness_read_files
CACHED_PATH=$REPO/tools/fitcache_cached_path

for f in "$SERVER_BIN" "$CLIENT_LIB" "$HARNESS_BIN" "$CACHED_PATH"; do
    [ -e "$f" ] || { echo "missing build artifact: $f" >&2; exit 2; }
done

# ----- Mercury / log4c env (matches build/build.sh) -----
export PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}:/lustre/orion/gen008/proj-shared/log4c-1.2.4/install/lib/pkgconfig:/lustre/orion/gen008/proj-shared/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}:/lustre/orion/gen008/proj-shared/log4c-1.2.4/install/lib:/lustre/orion/gen008/proj-shared/rlibrary/mercury2.0.1/lib
export PATH=/lustre/orion/gen008/proj-shared/mercury-2.0.1/build/bin:$PATH

# ----- Workspace -----
SMOKE_ROOT=/tmp/fitcachepp_migrate_smoke_$$
mkdir -p "$SMOKE_ROOT"/{dataset,registry,cache1_dram,cache1_nvme,cache2_dram,cache2_nvme,logs,cwd}
echo "smoke root: $SMOKE_ROOT"

# Dataset: file_0 is 10 MiB (real multi-page bulk transfer); a few small siblings.
head -c $((10 * 1024 * 1024)) /dev/urandom > "$SMOKE_ROOT/dataset/file_0.bin"
for i in 1 2 3; do head -c $((256 * 1024)) /dev/urandom > "$SMOKE_ROOT/dataset/file_$i.bin"; done
SRC_FILE="$SMOKE_ROOT/dataset/file_0.bin"
SRC_SUM=$(sha256sum "$SRC_FILE" | cut -d' ' -f1)
echo "dataset: file_0=10MiB (sha256=${SRC_SUM:0:16}...) + 3 small files"

# Common FitCache env (cross-job, shared registry, prefer migration)
export FitCache_DATA_DIR="$SMOKE_ROOT/dataset"
export FitCache_CROSS_JOB=1
export FitCache_PREFER_MIGRATE=1
export FitCache_CLUSTER_REGISTRY_DIR="$SMOKE_ROOT/registry"
export FitCache_HEARTBEAT_SEC=3
export FitCache_LOG_LEVEL=700
export FitCache_SERVER_COUNT=1
cd "$SMOKE_ROOT/cwd"

start_server() {
    local jobid=$1 procid=$2 dram=$3 nvme=$4 log=$5 selftest=${6:-}
    SLURM_JOBID=$jobid SLURM_PROCID=$procid \
    FitCache_DRAM_PATH=$dram FitCache_NVME_PATH=$nvme \
    FitCache_DRAM_CAPACITY=$((64 * 1024 * 1024)) \
    FitCache_NVME_CAPACITY=$((2 * 1024 * 1024 * 1024)) \
    FitCache_MIGRATE_SELFTEST="$selftest" \
    "$SERVER_BIN" 2 > "$log" 2>&1 &
    echo $!
}

wait_for_registry_entries() {
    local expect=$1 max_s=${2:-20}
    local nodes_dir="$SMOKE_ROOT/registry/registry.v1/nodes"
    for i in $(seq 1 "$max_s"); do
        local n=0
        [ -d "$nodes_dir" ] && n=$(grep -h '^server\..*\.addr=' "$nodes_dir"/*.txt 2>/dev/null | wc -l)
        [ "$n" -ge "$expect" ] && { echo "registry: $n server entr(y/ies) live after ${i}s"; return 0; }
        sleep 1
    done
    echo "registry: TIMEOUT waiting for $expect entries" >&2
    [ -d "$nodes_dir" ] && ls -la "$nodes_dir" >&2
    return 1
}

echo "=== Start S1 (jobid=1001) and S2 (jobid=1002, selftest=file_0) ==="
S1_PID=$(start_server 1001 0 "$SMOKE_ROOT/cache1_dram" "$SMOKE_ROOT/cache1_nvme" "$SMOKE_ROOT/logs/server1.log")
S2_PID=$(start_server 1002 1 "$SMOKE_ROOT/cache2_dram" "$SMOKE_ROOT/cache2_nvme" "$SMOKE_ROOT/logs/server2.log" "$SRC_FILE")
echo "S1 pid=$S1_PID  S2 pid=$S2_PID"
cleanup() { kill -TERM "$S1_PID" "$S2_PID" 2>/dev/null; sleep 1; kill -9 "$S1_PID" "$S2_PID" 2>/dev/null; }
trap cleanup EXIT
wait_for_registry_entries 2 || exit 3

echo "=== Client A (jobid=1001): read dataset through S1 -> S1 caches + broadcasts ==="
SLURM_JOBID=1001 SLURM_PROCID=0 \
  FitCache_DRAM_PATH="$SMOKE_ROOT/cache1_dram" FitCache_NVME_PATH="$SMOKE_ROOT/cache1_nvme" \
  FitCache_DRAM_CAPACITY=$((64 * 1024 * 1024)) FitCache_NVME_CAPACITY=$((2 * 1024 * 1024 * 1024)) \
  LD_PRELOAD="$CLIENT_LIB" "$HARNESS_BIN" "$SMOKE_ROOT/dataset" > "$SMOKE_ROOT/logs/client_a.log" 2>&1 \
  || { echo "client A failed"; tail -20 "$SMOKE_ROOT/logs/client_a.log"; exit 4; }
echo "client A done; S1 should now cache + broadcast file_0"

DST_FILE=$("$CACHED_PATH" "$SRC_FILE" "$SMOKE_ROOT/cache2_nvme")
echo "expecting migrated copy at: $DST_FILE"

echo "=== Wait (<=70s) for S2 self-test to migrate file_0 into cache2 ==="
OK=0
for i in $(seq 1 70); do
    if [ -f "$DST_FILE" ] && [ "$(stat -c %s "$DST_FILE" 2>/dev/null || echo 0)" = "$(stat -c %s "$SRC_FILE")" ]; then
        OK=1; echo "migrated file present after ${i}s"; break
    fi
    sleep 1
done

echo
echo "=== S2 server log: migration trace ==="
grep -E "MIGRATE_SELFTEST|migrate:|migrate serve|migrate pull|register_file" "$SMOKE_ROOT/logs/server2.log" | tail -25 || true
echo "=== S1 server log: promote + broadcast trace ==="
grep -E "Caching|Copied|broadcast|register_file" "$SMOKE_ROOT/logs/server1.log" | tail -15 || true

echo
echo "=== Verify ==="
EXIT=0
if [ "$OK" != "1" ]; then
    echo "FAIL: migrated copy did not appear at $DST_FILE within timeout" >&2
    EXIT=5
else
    DST_SUM=$(sha256sum "$DST_FILE" | cut -d' ' -f1)
    if [ "$DST_SUM" = "$SRC_SUM" ]; then
        echo "PASS: file_0 migrated S1->S2 over Mercury bulk; bytes identical (sha256 match)"
        echo "  src $SRC_FILE"
        echo "  dst $DST_FILE  ($(stat -c %s "$DST_FILE") bytes)"
    else
        echo "FAIL: migrated copy CONTENT mismatch (src=${SRC_SUM:0:16} dst=${DST_SUM:0:16})" >&2
        EXIT=6
    fi
fi
echo "logs: $SMOKE_ROOT/logs/"
exit $EXIT
