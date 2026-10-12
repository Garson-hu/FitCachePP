#!/bin/bash
#SBATCH -t 1-00:00:00
#SBATCH -J FitCachePP_remote_servers
#
# TPDS_FITPP_remote_servers.sh
#
# CosmoFlow launcher for the split layout used on ARC: every FitCache++ server
# runs on ONE memory-tier node (the PMem node in the IPDPS runs, the CXL node
# c28 now) and the Horovod training clients run on separate GPU nodes, reading
# through Mercury over the cluster network. TPDS_FITPP_inner.sh only covers
# servers and clients sharing a node.
#
# Runs either inside an sbatch/salloc allocation that holds the server node and
# the client nodes, or from a shell on the server node while the client nodes
# are held by another job (remote processes are started over ssh, which ARC
# allows on any node where the user has a job).
#
#   SERVER_NODE     node that runs all servers          (default: this host)
#   SERVERS         number of servers on SERVER_NODE    (default: site default)
#   CLIENT_NODES    space-separated GPU nodes           (default: SERVER_NODE)
#   GPUS_PER_NODE   GPUs used on each client node       (default: site default)
#   FITPP_PURE_CF=1 skip servers and LD_PRELOAD (PFS-only baseline)
#   FITPP_PURGE_CACHE=1 wipe the DRAM/NVMe tier dirs first
#   FITPP_N_TRAIN / FITPP_N_EPOCHS / FITPP_SEED  forwarded to train.py
#
# Tier paths/capacities (FitCache_{DRAM,PMEM,NVME}_{PATH,CAPACITY}) and
# FitCache_DATA_DIR may be pre-set by the caller; all paths are on SERVER_NODE.
# Set FitCache_CXL_PATH + FitCache_CXL_CAPACITY (bytes per server) to add the
# pooled CXL tier below DRAM; its index goes to FitCache_CXL_INDEX_PATH
# (default: the NVMe tier dir). The servers create the pool themselves.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/../sites" ]; then
    if [ -n "${FITPP_REPO:-}" ] && [ -d "$FITPP_REPO/benchmarks/sites" ]; then
        SCRIPT_DIR="$FITPP_REPO/benchmarks/cosmoflow"
    elif [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -d "$SLURM_SUBMIT_DIR/benchmarks/sites" ]; then
        SCRIPT_DIR="$SLURM_SUBMIT_DIR/benchmarks/cosmoflow"
    else
        echo "ERROR: cannot locate benchmarks/sites — set FITPP_REPO or run from repo root" >&2
        exit 1
    fi
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh"

THIS_NODE="$(hostname -s)"
SERVER_NODE="${SERVER_NODE:-$THIS_NODE}"
SERVERS="${SERVERS:-$FITPP_SERVERS_PER_NODE_DEFAULT}"
CLIENT_NODES="${CLIENT_NODES:-$SERVER_NODE}"
GPUS_PER_NODE="${GPUS_PER_NODE:-$FITPP_GPUS_PER_NODE_DEFAULT}"
read -a CLIENT_NODES_ARR <<< "$CLIENT_NODES"

TOTAL_GPUS=$(( ${#CLIENT_NODES_ARR[@]} * GPUS_PER_NODE ))
HOROVOD_HOSTLIST=""
for node in "${CLIENT_NODES_ARR[@]}"; do
    HOROVOD_HOSTLIST+="${node}:${GPUS_PER_NODE},"
done
HOROVOD_HOSTLIST=${HOROVOD_HOSTLIST%,}

# Server and client find each other through .ports.cfg.${SLURM_JOBID}, and the
# client refuses to start without SLURM_PROCID. Outside a SLURM batch
# environment neither exists, so make them up — and tell Open MPI to launch
# over ssh, because a SLURM_JOBID in the environment otherwise makes mpirun try
# srun against an allocation that does not exist.
if [ -z "${SLURM_JOB_ID:-}" ]; then
    RUN_ID="run$(date +%Y%m%d_%H%M%S)"
    export SLURM_PROCID=0
    export OMPI_MCA_plm=rsh
else
    RUN_ID="$SLURM_JOB_ID"
fi
export SLURM_JOBID="$RUN_ID"

# Client default is WARN (400): at INFO (600) the LD_PRELOAD'd client writes a
# per-Open RPC trace (fitcache_intercept_log.<pid>.<n>, 100 MB x 10 per python
# PID) into the cosmoflow benchmark dir; one day of runs filled the 40 GB home
# quota (2026-10-06). Export FitCache_LOG_LEVEL=600 explicitly when debugging.
# The servers keep INFO (FitCache_SERVER_LOG_LEVEL) so the "Open RPC" engagement
# self-check below still sees its lines.
export FitCache_LOG_LEVEL="${FitCache_LOG_LEVEL:-400}"
export RDMAV_FORK_SAFE=1
export FitCache_SERVER_COUNT="$SERVERS"
export FitCache_CROSS_JOB="${FitCache_CROSS_JOB:-0}"
export FitCache_DRAM_PATH="${FitCache_DRAM_PATH:-${FITPP_LOCAL_CACHE_ROOT}/fitcachepp_train_cache_dram}"
export FitCache_NVME_PATH="${FitCache_NVME_PATH:-${FITPP_LOCAL_CACHE_ROOT}/fitcachepp_train_cache_nvme}"
export FitCache_DRAM_CAPACITY="${FitCache_DRAM_CAPACITY:-$((100 * 1024 * 1024 * 1024))}"
export FitCache_NVME_CAPACITY="${FitCache_NVME_CAPACITY:-$((500 * 1024 * 1024 * 1024))}"
export FitCache_DATA_DIR="${FitCache_DATA_DIR:-${FITPP_COSMOFLOW_DATA_DEFAULT}}"
export BBPATH="$FitCache_NVME_PATH"

export RESULTS_DIR="${RESULTS_DIR:-${FITPP_RESULTS_ROOT}/remote_servers/${RUN_ID}}"
mkdir -p "$RESULTS_DIR"
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"
cd "$RESULTS_DIR"

echo "[$(date '+%H:%M:%S')] run=$RUN_ID server_node=$SERVER_NODE servers=$SERVERS clients=$HOROVOD_HOSTLIST"
echo "[$(date '+%H:%M:%S')] data=$FitCache_DATA_DIR n_train=${FITPP_N_TRAIN:-default} n_epochs=${FITPP_N_EPOCHS:-default}"

# Run a command on SERVER_NODE (locally when that is this host).
on_server_node() {
    if [ "$SERVER_NODE" = "$THIS_NODE" ]; then
        bash -c "$1"
    else
        ssh -o BatchMode=yes "$SERVER_NODE" "$1"
    fi
}

TIER_DIRS="$FitCache_DRAM_PATH $FitCache_NVME_PATH ${FitCache_PMEM_PATH:-}"
CXL_INDEX_DIR="${FitCache_CXL_INDEX_PATH:-$FitCache_NVME_PATH}"

# ------------------- Launch FitCache++ servers -------------------
if [ "${FITPP_PURE_CF:-0}" = "1" ]; then
    echo "[$(date '+%H:%M:%S')] FITPP_PURE_CF=1: no servers, no LD_PRELOAD (PFS-only baseline)"
else
    on_server_node "mkdir -p $TIER_DIRS"
    if [ "${FITPP_PURGE_CACHE:-0}" = "1" ]; then
        echo "[$(date '+%H:%M:%S')] FITPP_PURGE_CACHE=1: wiping $FitCache_DRAM_PATH and $FitCache_NVME_PATH on $SERVER_NODE"
        on_server_node "find $FitCache_DRAM_PATH $FitCache_NVME_PATH -mindepth 1 -delete 2>/dev/null; true"
        # Removing its index is what empties the CXL pool.
        on_server_node "rm -f $CXL_INDEX_DIR/cxl_pool.rank*.index"
    fi

    # ssh does not forward the environment, so hand the server everything it
    # reads (FitCache_*, the job id, the library path) explicitly.
    # Values are single-quoted: FitCache_HG_INFO holds a ';' which would
    # otherwise end the env command inside the server-side shell.
    SERVER_ENV="SLURM_JOBID=$RUN_ID LD_LIBRARY_PATH='$LD_LIBRARY_PATH' RDMAV_FORK_SAFE=1"
    # FitCache_* select the tiers and transport; FI_* steer libfabric (the GPU
    # nodes also carry Broadcom RoCE devices that libfabric lists before the
    # InfiniBand mlx5_0, so verbs needs FI_VERBS_IFACE=ib0 to pick the IB port).
    while IFS='=' read -r name value; do
        SERVER_ENV+=" $name='$value'"
    done < <(env | grep -E '^(FitCache_|FI_)')
    SERVER_ENV+=" FitCache_LOG_LEVEL=${FitCache_SERVER_LOG_LEVEL:-600}"   # servers stay at INFO (last assignment wins)

    echo "[$(date '+%H:%M:%S')] starting $SERVERS FitCache++ servers on $SERVER_NODE"
    for proc_id in $(seq 0 $((SERVERS - 1))); do
        # The server must be the backgrounded command itself (not the tail of
        # a "cd && ..." list), or \$! is a wrapper subshell and the kill at
        # teardown leaves the server running.
        on_server_node "cd $RESULTS_DIR || exit 1
            env $SERVER_ENV SLURM_PROCID=$proc_id \
                nohup $FITPP_SERVER_BIN $SERVERS > $RESULTS_DIR/server_${RUN_ID}_id${proc_id}.log 2>&1 &
            echo \$! >> $RESULTS_DIR/server_pids.${RUN_ID}"
    done

    for _ in $(seq 1 30); do
        n=$(grep -c '' "$RESULTS_DIR/.ports.cfg.$RUN_ID" 2>/dev/null)
        [ "${n:-0}" -ge "$SERVERS" ] && break
        sleep 2
    done
    if [ "${n:-0}" -lt "$SERVERS" ]; then
        echo "ERROR: only ${n:-0}/$SERVERS servers registered in .ports.cfg.$RUN_ID" >&2
        on_server_node "kill \$(cat $RESULTS_DIR/server_pids.${RUN_ID}) 2>/dev/null; true"
        exit 1
    fi
    echo "[$(date '+%H:%M:%S')] all $SERVERS server endpoints registered"
    # A CXL pool that cannot be set up makes the servers fall back to NVMe
    # silently (famfs contents vanish on a reboot). For an experiment that is
    # the wrong result, so stop here instead.
    if [ -n "${FitCache_CXL_PATH:-}" ]; then
        sleep 3
        if grep -qs 'CXL tier requested' "$RESULTS_DIR"/fitcache_server_log.*.0; then
            echo "ERROR: CXL pool at $FitCache_CXL_PATH could not be set up on $SERVER_NODE (see fitcache_server_log.*); aborting run" >&2
            on_server_node "kill \$(cat $RESULTS_DIR/server_pids.${RUN_ID}) 2>/dev/null; true"
            exit 1
        fi
    fi
fi

# ------------------- Launch training clients -------------------
CLIENT_LAUNCHER="${FITCACHE_CLIENT_LAUNCHER:-$SCRIPT_DIR/command_CF_FITPP.sh}"
if [ "$TOTAL_GPUS" -eq 1 ] && [ "${CLIENT_NODES_ARR[0]}" = "$THIS_NODE" ]; then
    echo "[$(date '+%H:%M:%S')] launching directly (single local GPU, no horovodrun)"
    "$CLIENT_LAUNCHER" 2>&1 | tee "$RESULTS_DIR/client_${RUN_ID}.log"
    CLIENT_RC=${PIPESTATUS[0]}
else
    echo "[$(date '+%H:%M:%S')] horovodrun -np $TOTAL_GPUS -H $HOROVOD_HOSTLIST"
    # First python start on a node with a cold page cache takes ~25 s over
    # NFS (longer when 8-16 nodes import at once), which trips horovodrun's
    # default 30 s start timeout.
    horovodrun --start-timeout 300 -np "$TOTAL_GPUS" -H "$HOROVOD_HOSTLIST" "$CLIENT_LAUNCHER" \
        2>&1 | tee "$RESULTS_DIR/horovodrun_${RUN_ID}.log"
    CLIENT_RC=${PIPESTATUS[0]}
fi
echo "[$(date '+%H:%M:%S')] client exit=$CLIENT_RC"

# ------------------- Cleanup + engagement self-check -------------------
if [ "${FITPP_PURE_CF:-0}" != "1" ]; then
    echo "[$(date '+%H:%M:%S')] tearing down FitCache++ servers on $SERVER_NODE"
    on_server_node "kill -TERM \$(cat $RESULTS_DIR/server_pids.${RUN_ID}) 2>/dev/null; sleep 2; \
                    kill -9 \$(cat $RESULTS_DIR/server_pids.${RUN_ID}) 2>/dev/null; true"

    OPEN_RPC_COUNT=$(grep -c 'Open RPC: requested path' "$RESULTS_DIR"/fitcache_server_log.*.0 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
    CACHED_FILE_COUNT=$(on_server_node "find $TIER_DIRS -type f ! -name '*.meta' ! -name 'cxl_pool.rank*.index' 2>/dev/null | wc -l")
    # Files in the CXL pool: one index line each, after a one-line header.
    POOLED=$(on_server_node "cat $CXL_INDEX_DIR/cxl_pool.rank*.index 2>/dev/null | grep -c \$'\t'")
    CACHED_FILE_COUNT=$(( ${CACHED_FILE_COUNT:-0} + ${POOLED:-0} ))
    if [ "$OPEN_RPC_COUNT" -eq 0 ] && [ "${CACHED_FILE_COUNT:-0}" -eq 0 ]; then
        echo "[$(date '+%H:%M:%S')] !!! WARNING !!! FitCache was NOT engaged: zero Open RPCs and zero cached files."
        echo "                Check that FitCache_DATA_DIR ($FitCache_DATA_DIR) is the path train.py reads."
    else
        echo "[$(date '+%H:%M:%S')] FitCache engaged: $OPEN_RPC_COUNT Open RPCs, ${CACHED_FILE_COUNT:-0} files cached on $SERVER_NODE."
    fi
fi

echo "[$(date '+%H:%M:%S')] DONE remote-servers run $RUN_ID (client_rc=$CLIENT_RC)"
exit $CLIENT_RC
