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

NODE="$(hostname -s)"
GPUS_PER_NODE="${GPUS_PER_NODE:-1}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
SERVER_BIN=/home/ghu4/hvac/FitCachePP/build/src/fitcache_server

# Each caller pre-sets RESULTS_DIR. Default to a generic per-job dir under
# benchmarks/results/ if not.
RESULTS_DIR="${RESULTS_DIR:-/home/ghu4/hvac/FitCachePP/benchmarks/results/job_${SLURM_JOB_ID}}"
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
CLIENT_LAUNCHER="${FITCACHE_CLIENT_LAUNCHER:-/home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/command_CF_FITPP.sh}"
echo "[$(date '+%H:%M:%S')] client launcher: $CLIENT_LAUNCHER"
# Megatron's pretrain script uses torchrun internally; CosmoFlow's uses
# horovodrun. The horovodrun wrapper is only needed for Horovod jobs.
# Detect which path to take by the launcher name; defaults to horovodrun.
if [[ "$CLIENT_LAUNCHER" == *megatron* ]] || [[ "$CLIENT_LAUNCHER" == *dinov2* ]]; then
    echo "[$(date '+%H:%M:%S')] launching directly (non-Horovod client)"
    "$CLIENT_LAUNCHER" 2>&1 | tee "$RESULTS_DIR/client_${SLURM_JOB_ID}.log"
    HOROVOD_RC=${PIPESTATUS[0]}
else
    echo "[$(date '+%H:%M:%S')] horovodrun -np $TOTAL_GPUS -H $HOROVOD_HOSTLIST"
    horovodrun -np "$TOTAL_GPUS" -H "$HOROVOD_HOSTLIST" \
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
for d in "$FitCache_DRAM_PATH" "$FitCache_NVME_PATH" "$FitCache_PMEM_PATH"; do
    [ -d "$d" ] || continue
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
