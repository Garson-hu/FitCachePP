#!/bin/bash
#
# run_sibling_cache_refresh_smoke.sh
#
# Cross-job sibling-cache refresh smoke. Validates the new mechanism that
# closes the per-server-process path_cache_map partitioning gap identified
# in the two-job concurrent cross-job-sharing run analysis:
#
#   Without sibling-refresh, every server process on a node maintains its
#   OWN in-process path_cache_map. When a peer_lookup_rpc arrives at
#   process P for a file process Q (on the same node) has cached, P
#   answers has=0 even though Q has written a .meta sidecar to the SAME
#   shared tier directory and the cached file is sitting on P's local
#   disk readable from P's process.
#
#   With sibling-refresh, P's background thread periodically (every
#   FitCache_SIBLING_REFRESH_SEC seconds, default 10) rescans the tier
#   directories and merges any newly-discovered sidecars into P's own
#   path_cache_map. After one refresh tick, P answers has=1 for anything
#   any sibling on this node has cached.
#
# Topology in this smoke:
#   - 2 FitCache server processes on localhost (S1 and S2), SAME jobid
#     (so they're "siblings" — multiple servers in one Slurm job).
#   - Both share the SAME FitCache_DRAM_PATH / NVME_PATH (shared tier dirs
#     on local disk — matches the realistic 4-server-per-node Cosmoflow
#     deployment, where every server process writes into the same tier).
#   - Cross-job mode enabled so the sibling-refresh thread fires.
#   - FitCache_SIBLING_REFRESH_SEC=2 — short interval so the test wall-clock
#     stays under 10s.
#
# What it does:
#   1. Build an 8-file synthetic dataset.
#   2. Start S1 (rank=0) and S2 (rank=1) with shared tier paths.
#   3. Run client A. The 8 opens HRW-route across S1+S2 in the same job;
#      each server caches whichever paths landed at it. Sidecars are
#      written to the shared tier dirs.
#   4. Wait > FitCache_SIBLING_REFRESH_SEC seconds for one refresh tick.
#   5. Grep both servers' logs for the new "sibling-refresh: merged N new
#      path_cache_map entries" line. After one tick, the server that
#      cached fewer files should report a non-zero N (it merged the other
#      server's sidecars). Both could report >=1 if HRW split 4-and-4.
#
# Exit 0 if at least one server logged a non-zero merged-entries line.

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
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}:/opt/ohpc/pub/compiler/gcc/9.4.0/lib64:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH

SMOKE_ROOT=/tmp/fitcachepp_sibling_refresh_smoke_$$
mkdir -p "$SMOKE_ROOT"/{dataset,registry,shared_dram,shared_nvme,cache_client_dram,cache_client_nvme,logs,cwd}
echo "smoke root: $SMOKE_ROOT"

for i in $(seq 0 7); do
    printf 'file_%d_payload_%s' "$i" "$(printf '%.0s.' {1..4000})" \
        > "$SMOKE_ROOT/dataset/file_$i.bin"
done
echo "dataset: 8 files in $SMOKE_ROOT/dataset/"

export FitCache_DATA_DIR="$SMOKE_ROOT/dataset"
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR="$SMOKE_ROOT/registry"
export FitCache_HEARTBEAT_SEC=2
export FitCache_LOG_LEVEL=700
export FitCache_SERVER_COUNT=2
# Short refresh interval so the smoke wall-clock is small. Production
# default is 10s; tighter here to avoid making the test slow.
export FitCache_SIBLING_REFRESH_SEC=2

cd "$SMOKE_ROOT/cwd"

start_sibling_server() {
    local procid=$1 log=$2
    SLURM_JOBID=2001 SLURM_PROCID=$procid \
    FitCache_DRAM_PATH="$SMOKE_ROOT/shared_dram" \
    FitCache_NVME_PATH="$SMOKE_ROOT/shared_nvme" \
    FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024)) \
    FitCache_NVME_CAPACITY=$((1024 * 1024 * 1024)) \
    "$SERVER_BIN" 2 > "$log" 2>&1 &
    echo $!
}

wait_for_registry_entries() {
    local expect=$1 max_s=${2:-15}
    local nodes_dir="$SMOKE_ROOT/registry/registry.v1/nodes"
    for i in $(seq 1 $max_s); do
        local n=0
        if [ -d "$nodes_dir" ]; then
            n=$(grep -h '^server\..*\.addr=' "$nodes_dir"/*.txt 2>/dev/null | wc -l)
        fi
        if [ "$n" -ge "$expect" ]; then
            echo "registry: $n server entr(y/ies) live after ${i}s"
            return 0
        fi
        sleep 1
    done
    echo "registry: TIMEOUT waiting for $expect server entries" >&2
    return 1
}

echo "=== Starting S1 (rank=0) and S2 (rank=1), same jobid=2001 (siblings), shared tier dirs ==="
S1_PID=$(start_sibling_server 0 "$SMOKE_ROOT/logs/server1.log")
S2_PID=$(start_sibling_server 1 "$SMOKE_ROOT/logs/server2.log")
echo "S1 pid=$S1_PID  S2 pid=$S2_PID"

wait_for_registry_entries 2 || { kill -9 "$S1_PID" "$S2_PID" 2>/dev/null; exit 3; }

echo "=== Running client (jobid=2001) — HRW will split opens between S1 and S2 ==="
SLURM_JOBID=2001 SLURM_PROCID=0 \
FitCache_DRAM_PATH="$SMOKE_ROOT/cache_client_dram" \
FitCache_NVME_PATH="$SMOKE_ROOT/cache_client_nvme" \
FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024)) \
FitCache_NVME_CAPACITY=$((1024 * 1024 * 1024)) \
LD_PRELOAD="$CLIENT_LIB" "$HARNESS_BIN" "$SMOKE_ROOT/dataset" \
    > "$SMOKE_ROOT/logs/client.log" 2>&1 || true

echo "client done. Waiting 4s (> FitCache_SIBLING_REFRESH_SEC=2) for a refresh tick to fire..."
sleep 4

echo "=== Shutting down servers ==="
kill -TERM "$S1_PID" "$S2_PID" 2>/dev/null || true
sleep 1
kill -9 "$S1_PID" "$S2_PID" 2>/dev/null || true

# Move log4c output adjacent to the captured stdout for archival.
mv "$SMOKE_ROOT/cwd"/fitcache_server_log.* "$SMOKE_ROOT/logs/" 2>/dev/null || true

# -------- Analysis --------
echo
echo "=== sibling-refresh log lines ==="
grep -h "sibling-refresh" "$SMOKE_ROOT/logs"/* 2>/dev/null | sort -u

echo
SIBREFRESH_HITS=$(grep -h "sibling-refresh: merged" "$SMOKE_ROOT/logs"/* 2>/dev/null \
                   | awk -F'merged ' '{print $2}' \
                   | awk '{print $1}' \
                   | awk '{s+=$1} END{print s+0}')

# Count total sidecars actually written across the shared tier dirs as a
# sanity check that the data mover ran.
SIDECAR_COUNT=$(find "$SMOKE_ROOT/shared_dram" "$SMOKE_ROOT/shared_nvme" -name '*.meta' 2>/dev/null | wc -l)

echo "=== Summary ==="
echo "shared-tier sidecars written by the data mover : $SIDECAR_COUNT"
echo "sibling-refresh merged entries across servers  : $SIBREFRESH_HITS"

EXIT=0
if [ "$SIDECAR_COUNT" -lt 1 ]; then
    echo "FAIL: data mover didn't write any sidecars. Cannot test sibling-refresh." >&2
    EXIT=5
elif [ "$SIBREFRESH_HITS" -lt 1 ]; then
    echo "FAIL: no sibling-refresh tick reported a non-zero merge despite $SIDECAR_COUNT sidecars on disk." >&2
    echo "      Either the refresh thread isn't running, or both servers were so symmetric they each cached every file themselves." >&2
    EXIT=6
fi

if [ "$EXIT" -eq 0 ]; then
    echo
    echo "PASS: sibling-refresh merged at least one entry from a sibling server's sidecars."
    echo "      (HRW split the 8 files across S1/S2; each server's refresh tick saw the OTHER's sidecars.)"
fi

echo
echo "smoke logs left at: $SMOKE_ROOT/logs/"
exit $EXIT
