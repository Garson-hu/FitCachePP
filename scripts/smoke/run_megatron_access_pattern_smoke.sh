#!/usr/bin/env bash
#
# run_megatron_access_pattern_smoke.sh
#
# Megatron-LM access-pattern smoke (no GPUs, no Megatron checkout required).
#
# Megatron's GPT pretraining reads tokenized data via the indexed-binary
# format:
#   <prefix>.bin   — concatenated tokens (uint16/uint32) packed as a single
#                    large mmap'd binary blob.
#   <prefix>.idx   — offset table: per-document (start, length, doc_idx)
#                    tuples for random-access training-document fetch.
# Typical access pattern under a streaming dataloader is:
#   - One open per .bin / .idx pair at process startup (file-level).
#   - Sequential streaming reads (or mmap) over the .bin chunks during the
#     entire training run.
# So the FitCache claim for this workload is: catch the open of the .bin
# and .idx, promote them into a tier, serve the streaming reads from
# cache, return Mercury bulk transfers fast enough that Megatron's
# dataloader doesn't notice.
#
# What this smoke does:
#   1. Generate synthetic .bin (a few MiB of random bytes) and a matching
#      .idx file under a fake `dataset_root`.
#   2. Run harness_read_files against `dataset_root` so every file gets
#      opened + read end-to-end via the LD_PRELOAD client.
#   3. Verify both files were promoted into a cache tier and that
#      sidecars (cross-job mode) were written.
#
# This is a NECESSARY check before a real Megatron-LM run: if the smoke
# fails, the LD_PRELOAD path-filter or the streaming-read interception is
# broken and a real GPU run would just produce a dormant FitCache.

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

SMOKE_ROOT=/tmp/fitcachepp_megatron_smoke_$$
mkdir -p "$SMOKE_ROOT"/{dataset,registry,dram,nvme,cwd,logs}
echo "[setup] smoke root: $SMOKE_ROOT"

# Synthesize the Megatron indexed-binary pair. The actual byte layout of
# the index doesn't matter for the smoke — we just need *files* shaped
# like Megatron's. 8 MiB .bin (token blob) + 64 KiB .idx (offset table).
SHARD_NAME=gpt2_pile_train_001
head -c $((8 * 1024 * 1024))  /dev/urandom > "$SMOKE_ROOT/dataset/${SHARD_NAME}.bin"
head -c $((64 * 1024))        /dev/urandom > "$SMOKE_ROOT/dataset/${SHARD_NAME}.idx"
echo "[setup] generated ${SHARD_NAME}.{bin,idx} = $(du -sh "$SMOKE_ROOT/dataset" | awk '{print $1}')"

cd "$SMOKE_ROOT/cwd"
export FitCache_DATA_DIR=$SMOKE_ROOT/dataset
export FitCache_CLUSTER_REGISTRY_DIR=$SMOKE_ROOT/registry
export FitCache_PORTS_CFG_DIR=$SMOKE_ROOT/cwd
export FitCache_HEARTBEAT_SEC=5
export FitCache_LOG_LEVEL=700                          # INFO + DEBUG so the smoke output is grep-friendly
export FitCache_SERVER_COUNT=1
export FitCache_DRAM_PATH=$SMOKE_ROOT/dram
export FitCache_NVME_PATH=$SMOKE_ROOT/nvme
export FitCache_DRAM_CAPACITY=$((64 * 1024 * 1024))    # plenty of headroom for 8 MiB + 64 KiB
export FitCache_NVME_CAPACITY=$((128 * 1024 * 1024))
export FitCache_CROSS_JOB=1                            # write sidecars so we can verify metadata-tagging
export SLURM_JOBID=${SLURM_JOBID:-9001}
export SLURM_PROCID=0

"$SERVER_BIN" 1 > "$SMOKE_ROOT/logs/server.log" 2>&1 &
SID=$!
sleep 3
if ! kill -0 "$SID" 2>/dev/null; then
    echo "[fatal] server died at startup; tail $SMOKE_ROOT/logs/server.log" >&2
    tail -40 "$SMOKE_ROOT/logs/server.log" >&2
    exit 3
fi

LD_PRELOAD=$CLIENT_LIB "$HARNESS_BIN" "$SMOKE_ROOT/dataset" > "$SMOKE_ROOT/logs/client.log" 2>&1
RC=$?

# Let the data mover finish promoting both shards before we count.
sleep 4

kill -TERM "$SID" 2>/dev/null || true
sleep 1
kill -9 "$SID" 2>/dev/null || true
wait "$SID" 2>/dev/null || true

# Move log4c output next to the rest for archival.
mv "$SMOKE_ROOT/cwd"/fitcache_server_log.* "$SMOKE_ROOT/logs/" 2>/dev/null || true
mv "$SMOKE_ROOT/cwd"/fitcache_intercept_log.* "$SMOKE_ROOT/logs/" 2>/dev/null || true

if [ $RC -ne 0 ]; then
    echo "[fatal] harness exited rc=$RC; tail $SMOKE_ROOT/logs/client.log" >&2
    tail -20 "$SMOKE_ROOT/logs/client.log" >&2
    exit 4
fi

cached_in() {
    local d=$1; local name=$2
    find "$d" -type f -name "$name" 2>/dev/null | head -1
}
sidecar_for() {
    local d=$1; local name=$2
    find "$d" -type f -name "$name.meta" 2>/dev/null | head -1
}

BIN_PATH=$(cached_in "$SMOKE_ROOT/dram" "${SHARD_NAME}.bin")
[ -z "$BIN_PATH" ] && BIN_PATH=$(cached_in "$SMOKE_ROOT/nvme" "${SHARD_NAME}.bin")
IDX_PATH=$(cached_in "$SMOKE_ROOT/dram" "${SHARD_NAME}.idx")
[ -z "$IDX_PATH" ] && IDX_PATH=$(cached_in "$SMOKE_ROOT/nvme" "${SHARD_NAME}.idx")

BIN_META=$(sidecar_for "$SMOKE_ROOT/dram" "${SHARD_NAME}.bin")
[ -z "$BIN_META" ] && BIN_META=$(sidecar_for "$SMOKE_ROOT/nvme" "${SHARD_NAME}.bin")
IDX_META=$(sidecar_for "$SMOKE_ROOT/dram" "${SHARD_NAME}.idx")
[ -z "$IDX_META" ] && IDX_META=$(sidecar_for "$SMOKE_ROOT/nvme" "${SHARD_NAME}.idx")

echo
echo "=== Megatron access-pattern smoke result ==="
echo "  ${SHARD_NAME}.bin     → cached=${BIN_PATH:-MISSING}    sidecar=${BIN_META:-MISSING}"
echo "  ${SHARD_NAME}.idx     → cached=${IDX_PATH:-MISSING}    sidecar=${IDX_META:-MISSING}"

fail=0
[ -z "$BIN_PATH" ] && { echo "[fail] .bin not promoted into any tier" >&2; fail=1; }
[ -z "$IDX_PATH" ] && { echo "[fail] .idx not promoted into any tier" >&2; fail=1; }
[ -z "$BIN_META" ] && { echo "[fail] .bin sidecar not written" >&2; fail=1; }
[ -z "$IDX_META" ] && { echo "[fail] .idx sidecar not written" >&2; fail=1; }

# Verify the cached payloads match the source byte-for-byte.
verify_byte_equal() {
    local src=$1; local cached=$2; local label=$3
    [ -z "$cached" ] && return
    local a=$(sha256sum "$src"   | awk '{print $1}')
    local b=$(sha256sum "$cached" | awk '{print $1}')
    if [ "$a" = "$b" ]; then
        echo "  $label  sha256 match"
    else
        echo "[fail] $label  sha256 mismatch ($a vs $b)" >&2
        fail=1
    fi
}
verify_byte_equal "$SMOKE_ROOT/dataset/${SHARD_NAME}.bin" "$BIN_PATH" "${SHARD_NAME}.bin"
verify_byte_equal "$SMOKE_ROOT/dataset/${SHARD_NAME}.idx" "$IDX_PATH" "${SHARD_NAME}.idx"

if [ $fail -ne 0 ]; then
    echo "[note] preserving $SMOKE_ROOT for inspection"
    exit 5
fi

echo
echo "[pass] Megatron access-pattern (.bin + .idx) goes through FitCache cleanly."
echo "       FitCache's path-filter / data mover / sidecar paths are workload-correct"
echo "       for the Megatron-LM training I/O shape."

if [ "${KEEP:-0}" = "0" ]; then
    rm -rf "$SMOKE_ROOT"
fi
