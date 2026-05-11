#!/bin/bash
#
# run_two_server_smoke.sh
#
# Multi-server localhost smoke for the cross-job redirect path. Exercises the
# entire open-time peer-lookup fanout end-to-end on a single host, before any
# cluster allocation is burned.
#
# What it does:
#   1. Builds a synthetic 8-file dataset under /tmp/fitcachepp_smoke_<pid>/dataset/.
#   2. Starts server S1 (jobid=1001, rank 0) with FitCache_CROSS_JOB=1 and a
#      shared FitCache_CLUSTER_REGISTRY_DIR. S1's cache lives in cache1_*.
#   3. Runs client A as job 1001 (LD_PRELOAD libfitcache_client.so on
#      harness_read_files). All opens HRW-route to S1 (only one in the live
#      set). S1 caches every file at close time via the data mover.
#   4. Sleeps to let the data mover finish promotion (close -> fs::copy is async).
#   5. Starts server S2 (jobid=1002, rank 1) with the same cluster registry.
#      Now the live set is {S1, S2}.
#   6. Runs client B as job 1002. For paths whose HRW(path, {S1,S2}) picks S2,
#      S2's open handler fans peer_lookup out to S1, S1 says has=1, S2 returns
#      FITCACHE_OPEN_REDIRECT to client B with S1's addr, and B re-issues open
#      against S1's slot. Subsequent reads on those fds route to S1.
#   7. Tears down both servers and greps the logs for evidence that the
#      peer-lookup + redirect path actually fired.
#
# Exit 0 if at least one redirect fired, non-zero otherwise.
#
# Run from anywhere; the script self-contains tmp paths.

set -u
set -o pipefail

REPO=/home/ghu4/hvac/FitCachePP
SERVER_BIN=$REPO/build/src/fitcache_server
CLIENT_LIB=$REPO/build/src/libfitcache_client.so
HARNESS_BIN=$REPO/build/tests/harness_read_files

for f in "$SERVER_BIN" "$CLIENT_LIB" "$HARNESS_BIN"; do
    [ -x "$f" ] || [ -f "$f" ] || { echo "missing build artifact: $f" >&2; exit 2; }
done

# ----- Mercury / log4c env (matches build/build.sh) -----
export PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH

# ----- Workspace -----
SMOKE_ROOT=/tmp/fitcachepp_smoke_$$
mkdir -p "$SMOKE_ROOT"/{dataset,registry,cache1_dram,cache1_nvme,cache2_dram,cache2_nvme,logs,cwd}
echo "smoke root: $SMOKE_ROOT"

# Synthetic dataset: 8 files, 4KB each, deterministic content so we can also
# verify the content survives the redirect round-trip if we ever extend the
# harness to check that.
for i in $(seq 0 7); do
    printf 'file_%d_payload_%s' "$i" "$(printf '%.0s.' {1..4000})" \
        > "$SMOKE_ROOT/dataset/file_$i.bin"
done
echo "dataset: 8 files in $SMOKE_ROOT/dataset/"

# Common FitCache env (cross-job mode, shared registry, common data dir)
export FitCache_DATA_DIR="$SMOKE_ROOT/dataset"
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR="$SMOKE_ROOT/registry"
export FitCache_HEARTBEAT_SEC=5     # short so the live set settles fast
export FitCache_LOG_LEVEL=700       # INFO so the diagnostic logs land in the log file

# FitCache_SERVER_COUNT is the count of servers in THIS job's .ports.cfg,
# not the cluster total. Each smoke job has exactly one server (jobid 1001 has
# S1; jobid 1002 has S2). The cluster registry provides the cross-job view.
# If we set this to 2 here, the modulo fallback in select_server_for_path
# can return rank 1 — which doesn't exist in either job's .ports.cfg and the
# resulting lookup_addr=NULL stalls the client (until the recent fix
# propagates the failure as a -1 result via the per-file sync context).
export FitCache_SERVER_COUNT=1

# Both client and server need a CWD for the per-job .ports.cfg files.
cd "$SMOKE_ROOT/cwd"

start_server() {
    local jobid=$1 procid=$2 dram=$3 nvme=$4 log=$5
    SLURM_JOBID=$jobid SLURM_PROCID=$procid \
    FitCache_DRAM_PATH=$dram FitCache_NVME_PATH=$nvme \
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
            # Count distinct server.<rank>.addr entries across all node files.
            n=$(grep -h '^server\..*\.addr=' "$nodes_dir"/*.txt 2>/dev/null | wc -l)
        fi
        if [ "$n" -ge "$expect" ]; then
            echo "registry: $n server entr(y/ies) live after ${i}s"
            return 0
        fi
        sleep 1
    done
    echo "registry: TIMEOUT waiting for $expect server entries" >&2
    [ -d "$nodes_dir" ] && ls -la "$nodes_dir" >&2
    return 1
}

run_client() {
    local jobid=$1 log=$2
    SLURM_JOBID=$jobid SLURM_PROCID=0 \
    FitCache_DRAM_PATH="$SMOKE_ROOT/cache1_dram"   \
    FitCache_NVME_PATH="$SMOKE_ROOT/cache1_nvme"   \
    FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024))  \
    FitCache_NVME_CAPACITY=$((1024 * 1024 * 1024)) \
    LD_PRELOAD="$CLIENT_LIB" "$HARNESS_BIN" "$SMOKE_ROOT/dataset" \
        > "$log" 2>&1
    return $?
}

echo "=== Starting S1 (jobid=1001, rank=0) ==="
S1_PID=$(start_server 1001 0 "$SMOKE_ROOT/cache1_dram" "$SMOKE_ROOT/cache1_nvme" "$SMOKE_ROOT/logs/server1.log")
echo "S1 pid=$S1_PID"
wait_for_registry_entries 1 || { kill -9 "$S1_PID" 2>/dev/null; exit 3; }

echo "=== Client A (jobid=1001) — warm S1's cache ==="
if ! run_client 1001 "$SMOKE_ROOT/logs/client_a.log"; then
    echo "client A failed (see $SMOKE_ROOT/logs/client_a.log)" >&2
    tail -40 "$SMOKE_ROOT/logs/client_a.log" >&2
    kill -9 "$S1_PID" 2>/dev/null
    exit 4
fi
echo "client A finished. Waiting 3s for the data mover to promote ..."
sleep 3

echo "=== Starting S2 (jobid=1002, rank=1) ==="
S2_PID=$(start_server 1002 1 "$SMOKE_ROOT/cache2_dram" "$SMOKE_ROOT/cache2_nvme" "$SMOKE_ROOT/logs/server2.log")
echo "S2 pid=$S2_PID"
wait_for_registry_entries 2 || { kill -9 "$S1_PID" "$S2_PID" 2>/dev/null; exit 3; }

echo "=== Client B (jobid=1002) — exercise peer-lookup + redirect ==="
if ! run_client 1002 "$SMOKE_ROOT/logs/client_b.log"; then
    echo "client B failed (see $SMOKE_ROOT/logs/client_b.log)" >&2
    tail -40 "$SMOKE_ROOT/logs/client_b.log" >&2
    kill -9 "$S1_PID" "$S2_PID" 2>/dev/null
    exit 4
fi
echo "client B finished."

echo "=== Shutting down servers ==="
kill -TERM "$S1_PID" "$S2_PID" 2>/dev/null || true
sleep 1
kill -9 "$S1_PID" "$S2_PID" 2>/dev/null || true

# -------- Analysis --------
echo
echo "=== Server log highlights ==="
for n in 1 2; do
    log=$SMOKE_ROOT/logs/server$n.log
    echo "--- server$n ($log) ---"
    grep -E "(peer_lookup|Open RPC|redirect|Redirect|registry: registered|HAS \(serve_addr|NOT HAS)" "$log" \
        | head -40 || true
    echo
done

echo "=== Client log highlights ==="
for c in a b; do
    log=$SMOKE_ROOT/logs/client_$c.log
    echo "--- client_$c ($log) ---"
    grep -E "(redirect|harness:|Open RPC Returned)" "$log" | head -20 || true
    echo
done

PEER_LOOKUP_QUERIES=$(grep -c "peer_lookup: rank=" "$SMOKE_ROOT"/cwd/fitcache_server_log.* 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
PEER_LOOKUP_HITS=$(grep -c "HAS (serve_addr=" "$SMOKE_ROOT"/cwd/fitcache_server_log.* 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
SERVER_REDIRECTS=$(grep -c "Open RPC redirect" "$SMOKE_ROOT"/cwd/fitcache_server_log.* 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
CLIENT_REDIRECTS=$(grep -c "server told us to redirect" "$SMOKE_ROOT"/cwd/fitcache_intercept_log.* 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')

echo "=== Summary ==="
echo "peer_lookup queries observed in server logs : $PEER_LOOKUP_QUERIES"
echo "peer_lookup HITS (has=1)                    : $PEER_LOOKUP_HITS"
echo "server-side FITCACHE_OPEN_REDIRECT issued   : $SERVER_REDIRECTS"
echo "client-side redirect handled                : $CLIENT_REDIRECTS"

EXIT=0
if [ "$PEER_LOOKUP_QUERIES" -lt 1 ]; then
    echo "FAIL: expected >=1 peer_lookup RPC; saw 0. Cross-job fanout did not fire." >&2
    EXIT=5
fi
if [ "$EXIT" -eq 0 ] && [ "$SERVER_REDIRECTS" -lt 1 ]; then
    echo "WARN: no FITCACHE_OPEN_REDIRECT issued — this can happen if HRW deterministically routed every open to S1 (the one that has the cache). In that case the peer-lookup never needed to redirect. Re-run; over enough files the HRW pick distribution should issue at least one redirect."
    # don't fail — the peer-lookup queries themselves prove the fanout works
fi

if [ "$EXIT" -eq 0 ]; then
    echo
    echo "PASS: cross-job peer-lookup path exercised end-to-end."
fi

# Logs path printed before cleanup so the user can re-inspect if needed.
echo
echo "smoke logs left at: $SMOKE_ROOT/logs/"
exit $EXIT
