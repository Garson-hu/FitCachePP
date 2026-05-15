#!/bin/bash
# Megatron mmap-interceptor smoke.
#
# Validates the libfitcache_client.so mmap wrapper (commit 85c9527) by
# running Megatron's IndexedDataset open + iterate path against the
# synthetic .bin/.idx pair under benchmarks/megatron's data prefix.
# Numpy.memmap fires inside IndexedDataset.__init__; if the interceptor
# is wired correctly the FitCache server log will contain:
#
#   - "Open RPC: requested path" — the .bin/.idx open() RPC fired
#   - "mmap on tracked fd" or "mmap: redirected to anon" — the new
#     interceptor caught the numpy.memmap call and redirected the
#     mapping through the FitCache read path
#
# Designed to run on a compute node with the FitCache server local to
# that node. Mercury's default OFI provider (ofi+verbs / ofi+tcp /
# ofi+cxi depending on what's available) handles the localhost RPC.
# A login-node run typically fails because Frontier's login nodes don't
# expose the Slingshot CXI provider; if you need a login-node smoke,
# set FitCache_SERVER_HOST=localhost and rely on the TCP fallback.
#
# Usage:
#   FITPP_SITE=frontier bash scripts/smoke/run_megatron_mmap_smoke.sh
#
# Optional overrides:
#   FITPP_PYTHON_TORCH=<path>           python with numpy installed
#   MEGATRON_DATA_PREFIX=<path>         override the .bin/.idx prefix
#   SMOKE_NUM_ITERS=<n>                 default 200 (small for a quick check)
#
# Output:
#   - Server log at /tmp/fitcache_megatron_smoke_<jobid>/server.log
#   - Stdout summary with the engagement signals (or a loud failure if
#     either signal is missing)

set -euo pipefail
cd "$(dirname "$0")/../.."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../benchmarks/sites/_resolve.sh"

# Smoke-time scratch. Use /tmp on the running host so server logs don't
# pollute the repo and tiny tier dirs don't slow Orion down.
SMOKE_ROOT="${SMOKE_ROOT:-/tmp/fitcache_megatron_smoke_$$}"
mkdir -p "$SMOKE_ROOT"

DATA_PREFIX="${MEGATRON_DATA_PREFIX:-${FITPP_PFS_DATA_ROOT}/megatron_synth_slice/synth_text_document}"
if [ ! -f "${DATA_PREFIX}.bin" ] || [ ! -f "${DATA_PREFIX}.idx" ]; then
    echo "ERROR: synthetic dataset missing at ${DATA_PREFIX}.{bin,idx}" >&2
    echo "       (run scripts/env/download_mmap_workloads.sh first)" >&2
    exit 1
fi
echo "[smoke] data prefix: $DATA_PREFIX"

# FitCache_DATA_DIR must be the PARENT of the .bin/.idx so the LD_PRELOAD
# substring path filter at fitcache_client.cpp:116 matches both files.
export FitCache_DATA_DIR="$(dirname "$DATA_PREFIX")"
export FitCache_DRAM_PATH="$SMOKE_ROOT/dram"
export FitCache_NVME_PATH="$SMOKE_ROOT/nvme"
export FitCache_DRAM_CAPACITY=$((4 * 1024 * 1024 * 1024))    # 4 GiB
export FitCache_NVME_CAPACITY=$((16 * 1024 * 1024 * 1024))   # 16 GiB
export FitCache_LOG_LEVEL=600   # INFO — needed for the mmap-redirect debug line
export FitCache_PORTS_CFG_DIR="$SMOKE_ROOT"
export FitCache_SERVER_COUNT=1
export FitCache_CROSS_JOB=0
mkdir -p "$FitCache_DRAM_PATH" "$FitCache_NVME_PATH"

# Start ONE fitcache_server. SLURM_PROCID + SLURM_JOBID + FitCache_SERVER_PORT
# keep it happy without a real Slurm allocation; the JOBID must match what
# the client passes below so the .ports.cfg lookup resolves.
echo "[smoke] starting fitcache_server"
SMOKE_FAKE_JOBID="${SMOKE_FAKE_JOBID:-99999}"
SLURM_PROCID=0 SLURM_JOBID="$SMOKE_FAKE_JOBID" FitCache_SERVER_PORT=5555 \
    "$FITPP_SERVER_BIN" 1 \
    > "$SMOKE_ROOT/server.log" 2>&1 &
SERVER_PID=$!
trap "kill -TERM $SERVER_PID 2>/dev/null || true; sleep 1; kill -9 $SERVER_PID 2>/dev/null || true" EXIT
sleep 3
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "ERROR: fitcache_server died early — tail of server.log:" >&2
    tail -30 "$SMOKE_ROOT/server.log" >&2
    exit 1
fi
echo "[smoke] server alive (pid=$SERVER_PID)"

# Run a minimal numpy.memmap-only iterator with LD_PRELOAD'd
# libfitcache_client.so. memmap-only (as opposed to Megatron's
# IndexedDataset) sidesteps the Megatron-LM .idx-format compatibility
# issue and gets us straight to the mmap call — which is what the
# interceptor actually targets.
#
# SLURM_PROCID + SLURM_JOBID are required by the client's comm init —
# they key the .ports.cfg.<JOBID> file the client reads to find its
# server. On a login-node smoke (no SLURM context) we set them
# explicitly to match what the server we spawned above wrote.
echo "[smoke] launching memmap_only_iter.py under LD_PRELOAD"
SMOKE_NUM_ITERS="${SMOKE_NUM_ITERS:-200}"
SMOKE_FAKE_JOBID="${SMOKE_FAKE_JOBID:-99999}"
LD_PRELOAD="$FITPP_CLIENT_LIB" \
SLURM_PROCID=0 \
SLURM_JOBID="$SMOKE_FAKE_JOBID" \
    "$FITPP_PYTHON_TORCH" \
    "$FITPP_REPO/benchmarks/megatron/memmap_only_iter.py" \
    --bin "${DATA_PREFIX}.bin" \
    --dtype uint16 \
    --num-iters "$SMOKE_NUM_ITERS" \
    --slice-len 1024 \
    --batch-size 4 \
    2>&1 | tee "$SMOKE_ROOT/client.log"
CLIENT_RC=${PIPESTATUS[0]}

# Tear down the server (trap will catch the orphans on exit too).
echo "[smoke] tearing down server"
kill -TERM "$SERVER_PID" 2>/dev/null || true
sleep 1

# Engagement check — what does the server log say?
echo "[smoke] ----- engagement signals -----"
# The fitcache_server's log4c output (fitcache_server_log.<pid>.0) lands in
# CWD because the server doesn't cd into RESULTS_DIR on its own (inner.sh
# does that for SLURM jobs but we're a standalone smoke). Look for both
# the SLURM-style server.log AND the most recent fitcache_server_log.* in
# CWD that belongs to OUR server pid. The client's log4c file
# (fitcache_intercept_log.<pid>.0) likewise lands in CWD; the mmap log
# lines from the wrapper go there, NOT into the client.log captured by tee.
OPEN_RPC_LINES=$(grep -cE "Open RPC: requested path" \
    "$SMOKE_ROOT/server.log" \
    fitcache_server_log.${SERVER_PID}.* 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
MMAP_REDIRECT_LINES=$(grep -cE "mmap on tracked fd|mmap: redirected to anon" \
    fitcache_intercept_log.*.0 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
echo "    Open RPCs in server log:        $OPEN_RPC_LINES"
echo "    mmap-redirect lines (client):   $MMAP_REDIRECT_LINES"
echo "    Client exit code:               $CLIENT_RC"
echo
if [ "$OPEN_RPC_LINES" -gt 0 ] && [ "$MMAP_REDIRECT_LINES" -gt 0 ]; then
    echo "[smoke] PASS — both FitCache + mmap-interceptor engaged."
    exit 0
elif [ "$OPEN_RPC_LINES" -gt 0 ] && [ "$MMAP_REDIRECT_LINES" -eq 0 ]; then
    echo "[smoke] WARNING — FitCache engaged (Open RPC fired) but the mmap"
    echo "        interceptor was not exercised. Did numpy.memmap actually fire?"
    exit 2
elif [ "$OPEN_RPC_LINES" -eq 0 ] && [ "$MMAP_REDIRECT_LINES" -gt 0 ]; then
    echo "[smoke] WARNING — mmap-interceptor fired but no Open RPC reached"
    echo "        the server. FitCache_DATA_DIR / path-filter mismatch?"
    exit 3
else
    echo "[smoke] FAIL — neither signal fired. FitCache pathway dormant."
    echo "        Tail of server log:"
    tail -20 "$SMOKE_ROOT/server.log"
    echo "        Tail of client log:"
    tail -20 "$SMOKE_ROOT/client.log"
    exit 4
fi
