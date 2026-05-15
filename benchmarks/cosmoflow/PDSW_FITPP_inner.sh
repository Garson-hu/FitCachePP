#!/bin/bash
#
# PDSW_FITPP_inner.sh
#
# Common launcher for the FitCache++ CosmoFlow benchmarks. Spawns
# SERVERS_PER_NODE FitCache++ servers on the local SLURM-allocated node
# (each on a distinct port + SLURM_PROCID) and then runs Horovod CosmoFlow
# training as a single GPU client. Designed to be invoked from inside a
# SLURM batch script that has already exported the FitCache_* env vars
# (FitCache_CROSS_JOB, FitCache_CLUSTER_REGISTRY_DIR, FitCache_DRAM_PATH,
# FitCache_NVME_PATH, FitCache_DRAM_CAPACITY, FitCache_NVME_CAPACITY,
# FitCache_DATA_DIR, FitCache_SERVER_COUNT) plus the Mercury / log4c
# PATH/LD_LIBRARY_PATH/PKG_CONFIG_PATH.
#
# The inner script knows nothing about the batch script's experiment intent;
# it just brings up the FitCache++ servers + Horovod client and tears them
# down. Callers (PDSW_FITPP.sh / PDSW_FITPP_two_job_*.sh) wrap with the
# specific FitCache_CROSS_JOB / registry / cache-path config they need.

set -u

# Resolve site (sets FITPP_REPO / FITPP_SERVER_BIN / FITPP_RESULTS_ROOT /
# FITPP_COSMOFLOW_DIR / FITPP_SERVERS_PER_NODE_DEFAULT / etc.).
# Same sbatch-script-copy fallback as PDSW_FITPP.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/../sites" ]; then
    if [ -n "${FITPP_REPO:-}" ] && [ -d "$FITPP_REPO/benchmarks/sites" ]; then
        SCRIPT_DIR="$FITPP_REPO/benchmarks/cosmoflow"
    elif [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -d "$SLURM_SUBMIT_DIR/benchmarks/sites" ]; then
        SCRIPT_DIR="$SLURM_SUBMIT_DIR/benchmarks/cosmoflow"
    else
        echo "ERROR: cannot locate benchmarks/sites — set FITPP_REPO" >&2
        exit 1
    fi
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh"

NODE="$(hostname -s)"
GPUS_PER_NODE="${GPUS_PER_NODE:-$FITPP_GPUS_PER_NODE_DEFAULT}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-$FITPP_SERVERS_PER_NODE_DEFAULT}"
SERVER_BIN="$FITPP_SERVER_BIN"

# Each caller pre-sets RESULTS_DIR. Default to a generic per-job dir under
# the site's results root if not.
RESULTS_DIR="${RESULTS_DIR:-${FITPP_RESULTS_ROOT}/job_${SLURM_JOB_ID}}"
mkdir -p "$RESULTS_DIR"

# Run the server processes with $RESULTS_DIR as their CWD so log4c's per-pid
# files (fitcache_server_log.<pid>.<rank>) land alongside the rest of the
# job's outputs instead of polluting the repo root. The horovodrun client
# also runs from here (CWD inherits to its children — the LD_PRELOAD'd
# python doesn't care about the cwd since it gets configs/cosmo.yaml via
# the cd inside command_CF_FITPP.sh).
cd "$RESULTS_DIR"

# Pin the .ports.cfg.<JOBID> location so server (which lands here after
# `cd "$RESULTS_DIR"`) and client (which cd's into the training dir for
# configs/cosmo.yaml inside command_CF_FITPP.sh) agree on where to write
# and read the server-endpoint config. Without this, the client's
# fitcache_client_comm_lookup_addr can't find the .ports.cfg and either
# segfaults (if not patched) or returns NULL hg_addr.
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"

# FitCache_SERVER_COUNT must equal SERVERS_PER_NODE * (number of server
# nodes). Inner script handles single-node only; multi-node would need a
# different orchestration pattern.
if [ "${FitCache_SERVER_COUNT:-0}" -ne "$SERVERS_PER_NODE" ]; then
    echo "ERROR: FitCache_SERVER_COUNT=${FitCache_SERVER_COUNT:-0} != SERVERS_PER_NODE=$SERVERS_PER_NODE"
    exit 1
fi

# Pre-create cache dirs so multiple servers on the same node don't race.
mkdir -p "$FitCache_DRAM_PATH" "$FitCache_NVME_PATH"

# Sweep stale fitcache_intercept_log.* files in the cosmoflow benchmark dir.
# These are the LD_PRELOAD client's log4c outputs (one per python PID per
# run) and accumulate across runs in $FITPP_COSMOFLOW_DIR. They've already
# pushed the home quota over the limit once on arc (causing 221680 to crash
# on history.csv write). Only sweep files older than 5 minutes so we don't
# delete anything a currently-running job is still writing to. Errors are
# non-fatal — quota may already be tight; skip on failure.
{
    find "$FITPP_COSMOFLOW_DIR" \
         -maxdepth 1 -name 'fitcache_intercept_log.*' -mmin +5 -delete 2>/dev/null
    n=$(find "$FITPP_COSMOFLOW_DIR" \
              -maxdepth 1 -name 'fitcache_intercept_log.*' 2>/dev/null | wc -l)
    echo "[$(date '+%H:%M:%S')] swept stale intercept logs; $n remain (younger than 5 min, in-use)"
} || echo "[warn] intercept log sweep failed (continuing)"

# When the same physical cache dir is reused across runs (single-node
# experiments often pin DRAM/NVMe paths to /mnt/local/ghu4/<fixed>),
# leftover files from prior runs corrupt the engagement self-check's
# cached-file count and pollute restore-sidecars at startup. Wipe under
# the live tier paths if FITPP_PURGE_CACHE=1 is set (default OFF so
# back-to-back runs that intentionally want to reuse cache don't lose it).
if [ "${FITPP_PURGE_CACHE:-0}" = "1" ]; then
    echo "[$(date '+%H:%M:%S')] FITPP_PURGE_CACHE=1: wiping $FitCache_DRAM_PATH and $FitCache_NVME_PATH"
    find "$FitCache_DRAM_PATH" -mindepth 1 -delete 2>/dev/null || true
    find "$FitCache_NVME_PATH" -mindepth 1 -delete 2>/dev/null || true
fi

# ------------------- Launch FitCache++ servers -------------------
echo "[$(date '+%H:%M:%S')] Starting $SERVERS_PER_NODE FitCache++ servers on $NODE (jobid=$SLURM_JOB_ID, cross_job=${FitCache_CROSS_JOB:-0})"
SERVER_PIDS=()
BASE_PORT=5555

for proc_id in $(seq 0 $((SERVERS_PER_NODE - 1))); do
    PORT=$((BASE_PORT + proc_id))
    SLURM_PROCID=$proc_id \
    FitCache_SERVER_PORT=$PORT \
        "$SERVER_BIN" "$FitCache_SERVER_COUNT" \
        > "$RESULTS_DIR/server_${SLURM_JOB_ID}_id${proc_id}.log" 2>&1 &
    SERVER_PIDS+=($!)
    echo "  [$(date '+%H:%M:%S')]   Server proc=$proc_id port=$PORT pid=${SERVER_PIDS[-1]}"
done

# Give the servers a few seconds to bind ports + register.
sleep 5

# ------------------- Launch training client -------------------
# FITCACHE_CLIENT_LAUNCHER lets a caller swap in a different LD_PRELOAD'd
# training command (e.g. Megatron-LM via command_megatron_FITPP.sh,
# DINOv2 via command_dinov2_FITPP.sh) without forking inner.sh. Defaults
# to the CosmoFlow command.
TOTAL_GPUS=$GPUS_PER_NODE
HOROVOD_HOSTLIST="${NODE}:${GPUS_PER_NODE}"
CLIENT_LAUNCHER="${FITCACHE_CLIENT_LAUNCHER:-${SCRIPT_DIR}/command_CF_FITPP.sh}"
echo "[$(date '+%H:%M:%S')] client launcher: $CLIENT_LAUNCHER"
# Megatron's pretrain script uses torchrun internally; CosmoFlow's uses
# horovodrun. The horovodrun wrapper is only needed for Horovod jobs.
# Detect which path to take by the launcher name; defaults to horovodrun.
if [[ "$CLIENT_LAUNCHER" == *megatron* ]] || [[ "$CLIENT_LAUNCHER" == *dinov2* ]]; then
    echo "[$(date '+%H:%M:%S')] launching directly (non-Horovod client)"
    "$CLIENT_LAUNCHER" 2>&1 | tee "$RESULTS_DIR/client_${SLURM_JOB_ID}.log"
    HOROVOD_RC=${PIPESTATUS[0]}
elif [ "$TOTAL_GPUS" -eq 1 ]; then
    # Single-GPU runs don't need horovodrun's process-launching layer — hvd.init()
    # inside the python process is enough. Bypass the launcher entirely so we
    # don't depend on horovodrun's mpirun/gloo backend (this env was built
    # without gloo and Frontier has no mpirun, so horovodrun crashes either way).
    echo "[$(date '+%H:%M:%S')] launching directly (single-GPU, no horovodrun)"
    "$CLIENT_LAUNCHER" 2>&1 | tee "$RESULTS_DIR/client_${SLURM_JOB_ID}.log"
    HOROVOD_RC=${PIPESTATUS[0]}
else
    # Multi-GPU / multi-node: needs a real launcher. On Frontier, prefer srun
    # over horovodrun since cray-mpich has no mpirun. --gloo bypasses mpirun
    # but requires horovod to have been built with HOROVOD_WITH_GLOO=1.
    HVDRUN_BACKEND="${FITPP_HVDRUN_BACKEND:-}"
    if [ -z "$HVDRUN_BACKEND" ] && [ "${FITPP_SITE:-}" = "frontier" ]; then
        HVDRUN_BACKEND="--gloo"
    fi
    echo "[$(date '+%H:%M:%S')] horovodrun $HVDRUN_BACKEND -np $TOTAL_GPUS -H $HOROVOD_HOSTLIST"
    horovodrun $HVDRUN_BACKEND -np "$TOTAL_GPUS" -H "$HOROVOD_HOSTLIST" \
        "$CLIENT_LAUNCHER" \
        2>&1 | tee "$RESULTS_DIR/horovodrun_${SLURM_JOB_ID}.log"
    HOROVOD_RC=${PIPESTATUS[0]}
fi
echo "[$(date '+%H:%M:%S')] client exit=$HOROVOD_RC"

# ------------------- Cleanup -------------------
echo "[$(date '+%H:%M:%S')] Tearing down FitCache++ servers"
for pid in "${SERVER_PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
done
sleep 2
for pid in "${SERVER_PIDS[@]}"; do
    kill -9 "$pid" 2>/dev/null || true
done

# Engagement self-check. A FitCache cluster run is only quotable if at least
# one server actually saw an "Open RPC: requested path" message — otherwise
# the LD_PRELOAD client never intercepted, every read went straight to the
# PFS, and the resulting epoch timings tell us nothing about FitCache. This
# happened across 2026-05-11's cluster runs (root cause: FitCache_DATA_DIR
# vs train.py --data-dir mismatch); the check below prevents it from
# happening silently again.
# Two independent engagement signals:
#   (a) "Open RPC: requested path" lines in the server log4c file. These are
#       emitted at INFO level (priority 600). If FitCache_LOG_LEVEL is set
#       below INFO (e.g. NOTICE=500), the lines are filtered and the count
#       is zero even when FitCache *is* engaged.
#   (b) the number of files actually promoted into the cache tier dirs.
#       Independent of log level: if FitCache caught at least one open,
#       the data mover copied at least one file into DRAM/NVMe/PMem.
# Treat the run as engaged if EITHER signal fires. False-negative on (a)
# alone produces a noisy warning but doesn't suppress (b).
OPEN_RPC_COUNT=$(grep -c 'Open RPC: requested path' "$RESULTS_DIR"/fitcache_server_log.*.0 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
CACHED_FILE_COUNT=0
# Use ${VAR:-} expansion so "set -u" doesn't fail when single-job runs
# (which don't set FitCache_PMEM_PATH) reach this loop.
for d in "${FitCache_DRAM_PATH:-}" "${FitCache_NVME_PATH:-}" "${FitCache_PMEM_PATH:-}"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    n=$(find "$d" -type f ! -name '*.meta' 2>/dev/null | wc -l)
    CACHED_FILE_COUNT=$((CACHED_FILE_COUNT + n))
done

if [ "$OPEN_RPC_COUNT" -eq 0 ] && [ "$CACHED_FILE_COUNT" -eq 0 ]; then
    echo "[$(date '+%H:%M:%S')] !!! WARNING !!! No FitCache engagement signal: zero Open RPC log lines"
    echo "                AND zero cached files in DRAM/NVMe/PMem tier dirs."
    echo "                FitCache was NOT engaged this run. Most likely cause:"
    echo "                FitCache_DATA_DIR ($FitCache_DATA_DIR) doesn't match the path"
    echo "                train.py actually reads (check configs/cosmo.yaml and the"
    echo "                --data-dir passed in command_CF_FITPP.sh). Epoch timings"
    echo "                from this run are NOT FitCache-attributable."
elif [ "$OPEN_RPC_COUNT" -eq 0 ] && [ "$CACHED_FILE_COUNT" -gt 0 ]; then
    echo "[$(date '+%H:%M:%S')] FitCache engaged: $CACHED_FILE_COUNT files in cache tiers."
    echo "                (Open RPC log count was 0 — that's INFO-level so a"
    echo "                FitCache_LOG_LEVEL<600 setting filters it; the cached"
    echo "                file count is the authoritative signal.)"
else
    echo "[$(date '+%H:%M:%S')] FitCache engaged: $OPEN_RPC_COUNT Open RPCs handled across all servers; $CACHED_FILE_COUNT files cached."
fi

echo "[$(date '+%H:%M:%S')] DONE FitCache++ inner (job $SLURM_JOB_ID, horovod_rc=$HOROVOD_RC)"
exit $HOROVOD_RC
