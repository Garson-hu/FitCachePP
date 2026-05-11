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

# ------------------- Launch CosmoFlow training -------------------
TOTAL_GPUS=$GPUS_PER_NODE
HOROVOD_HOSTLIST="${NODE}:${GPUS_PER_NODE}"
echo "[$(date '+%H:%M:%S')] horovodrun -np $TOTAL_GPUS -H $HOROVOD_HOSTLIST"
horovodrun -np "$TOTAL_GPUS" -H "$HOROVOD_HOSTLIST" \
    /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/command_CF_FITPP.sh \
    2>&1 | tee "$RESULTS_DIR/horovodrun_${SLURM_JOB_ID}.log"
HOROVOD_RC=${PIPESTATUS[0]}
echo "[$(date '+%H:%M:%S')] horovodrun exit=$HOROVOD_RC"

# ------------------- Cleanup -------------------
echo "[$(date '+%H:%M:%S')] Tearing down FitCache++ servers"
for pid in "${SERVER_PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
done
sleep 2
for pid in "${SERVER_PIDS[@]}"; do
    kill -9 "$pid" 2>/dev/null || true
done

echo "[$(date '+%H:%M:%S')] DONE FitCache++ inner (job $SLURM_JOB_ID, horovod_rc=$HOROVOD_RC)"
exit $HOROVOD_RC
