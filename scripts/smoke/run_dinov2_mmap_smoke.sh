#!/bin/bash
# DINOv2 mmap-interceptor smoke (login-node).
# Mirrors run_megatron_mmap_smoke.sh but exercises the many-small-files
# pattern that DINOv2's ImageNet22k loader generates. Each image is
# open + mmap + touch + munmap; the mmap wrapper should fire once per
# image and the FitCache server should log one Open RPC per first-time
# file open.
#
# Usage:
#   FITPP_SITE=frontier bash scripts/smoke/run_dinov2_mmap_smoke.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../benchmarks/sites/_resolve.sh"

SMOKE_ROOT="${SMOKE_ROOT:-/tmp/fitcache_dinov2_smoke_$$}"
mkdir -p "$SMOKE_ROOT"

DINOV2_ROOT="${DINOV2_DATA_ROOT:-${FITPP_PFS_DATA_ROOT}/dinov2/imagenet_synth}"
if [ ! -d "$DINOV2_ROOT" ]; then
    echo "ERROR: DINOv2 stand-in missing at $DINOV2_ROOT" >&2
    echo "       (run scripts/env/stage_megatron_dinov2_data.sh first)" >&2
    exit 1
fi
echo "[smoke] dinov2 root: $DINOV2_ROOT"

export FitCache_DATA_DIR="$DINOV2_ROOT"
export FitCache_DRAM_PATH="$SMOKE_ROOT/dram"
export FitCache_NVME_PATH="$SMOKE_ROOT/nvme"
export FitCache_DRAM_CAPACITY=$((4 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((16 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="$SMOKE_ROOT"
export FitCache_SERVER_COUNT=1
export FitCache_CROSS_JOB=0
mkdir -p "$FitCache_DRAM_PATH" "$FitCache_NVME_PATH"

SMOKE_FAKE_JOBID="${SMOKE_FAKE_JOBID:-99998}"
echo "[smoke] starting fitcache_server"
SLURM_PROCID=0 SLURM_JOBID="$SMOKE_FAKE_JOBID" FitCache_SERVER_PORT=5556 \
    "$FITPP_SERVER_BIN" 1 \
    > "$SMOKE_ROOT/server.log" 2>&1 &
SERVER_PID=$!
trap "kill -TERM $SERVER_PID 2>/dev/null || true; sleep 1; kill -9 $SERVER_PID 2>/dev/null || true" EXIT
sleep 3
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "ERROR: fitcache_server died early" >&2
    tail -20 "$SMOKE_ROOT/server.log" >&2
    exit 1
fi
echo "[smoke] server alive (pid=$SERVER_PID)"

echo "[smoke] launching dinov2_io_only_iter.py under LD_PRELOAD"
SMOKE_NUM_ITERS="${SMOKE_NUM_ITERS:-200}"
LD_PRELOAD="$FITPP_CLIENT_LIB" \
SLURM_PROCID=0 SLURM_JOBID="$SMOKE_FAKE_JOBID" \
    "$FITPP_PYTHON_TORCH" \
    "$FITPP_REPO/benchmarks/dinov2/dinov2_io_only_iter.py" \
    --root "$DINOV2_ROOT" \
    --num-iters "$SMOKE_NUM_ITERS" \
    --batch-size 4 \
    2>&1 | tee "$SMOKE_ROOT/client.log"
CLIENT_RC=${PIPESTATUS[0]}

echo "[smoke] tearing down server"
kill -TERM "$SERVER_PID" 2>/dev/null || true
sleep 1

echo "[smoke] ----- engagement signals -----"
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
    echo "[smoke] PASS — DINOv2 mmap pattern engages both FitCache + interceptor."
    exit 0
else
    echo "[smoke] FAIL — Open=$OPEN_RPC_LINES mmap=$MMAP_REDIRECT_LINES"
    exit 1
fi
