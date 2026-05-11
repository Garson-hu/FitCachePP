#!/bin/bash
#SBATCH -p all
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_multinode
#SBATCH -o /home/ghu4/hvac/FitCachePP/benchmarks/results/multinode_baseline/FitCachePP_multinode-%j.out
#
# FitCache++ multi-node experiment driver.
# Models the IPDPS layout from PDSW_Exps.sh: storage-server nodes (c35/c36
# with PMem at /mnt/fsdax) run the FitCache servers; GPU nodes run the
# Horovod training client. The two are connected by Mercury over the
# cluster's network.
#
# Submit with: sbatch -w c35,<gpu_node>  PDSW_FITPP_multinode.sh
# Defaults: detects c35 (and c36 if allocated) as PMem node(s), all
# others as client/GPU nodes.
#
# Three-tier on storage nodes:
#   FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_multinode_dram
#   FitCache_PMEM_PATH=/mnt/fsdax/ghu4/fitcachepp_multinode_pmem   (c35/c36 only)
#   FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_multinode_nvme

set -u

# ---------------- Detect PMem nodes vs client nodes ----------------
ALL_NODES=$(scontrol show hostname $SLURM_JOB_NODELIST | tr "\n" " ")
echo "Allocated nodes: $ALL_NODES"
POSSIBLE_PM_NODES=(c35 c36)

PM_NODES=()
CLIENT_NODES=()
for n in $ALL_NODES; do
    is_pm=0
    for p in "${POSSIBLE_PM_NODES[@]}"; do
        [ "$n" = "$p" ] && is_pm=1
    done
    if [ "$is_pm" = "1" ]; then PM_NODES+=("$n"); else CLIENT_NODES+=("$n"); fi
done

if [ ${#PM_NODES[@]} -eq 0 ]; then
    echo "ERROR: no PMem-capable storage node (c35/c36) in allocation. salloc with -w c35,<gpu_node>." >&2
    exit 1
fi
if [ ${#CLIENT_NODES[@]} -eq 0 ]; then
    echo "ERROR: no client node in allocation (only PMem nodes). need at least one GPU node." >&2
    exit 1
fi
echo "PMem storage nodes: ${PM_NODES[*]}"
echo "GPU client nodes  : ${CLIENT_NODES[*]}"

# ---------------- Server topology (matches IPDPS shape) ----------------
SERVERS_PER_PM_NODE=${SERVERS_PER_PM_NODE:-4}
TOTAL_SERVERS=$((${#PM_NODES[@]} * SERVERS_PER_PM_NODE))
export FitCache_SERVER_COUNT=$TOTAL_SERVERS

GPUS_PER_NODE=${GPUS_PER_NODE:-1}
TOTAL_GPUS=$((${#CLIENT_NODES[@]} * GPUS_PER_NODE))
HOROVOD_HOSTLIST=""
for n in "${CLIENT_NODES[@]}"; do HOROVOD_HOSTLIST+="${n}:${GPUS_PER_NODE},"; done
HOROVOD_HOSTLIST=${HOROVOD_HOSTLIST%,}

# ---------------- Mercury / log4c env ----------------
export FitCache_LOG_LEVEL=600
export RDMAV_FORK_SAFE=1
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/rlibrary/miniconda3/envs/hvac_tf/bin:/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH

# ---------------- Tier paths + capacity ----------------
# DRAM and NVMe are on the storage node's local /mnt/local (shared name
# across all PM nodes — c35 and c36 each have their own /mnt/local).
# PMem at /mnt/fsdax is also per-node.
export FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_multinode_dram
export FitCache_PMEM_PATH=/mnt/fsdax/ghu4/fitcachepp_multinode_pmem
export FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_multinode_nvme
export FitCache_DRAM_CAPACITY=$((20  * 1024 * 1024 * 1024))   # 20 GiB
export FitCache_PMEM_CAPACITY=$((300 * 1024 * 1024 * 1024))   # 300 GiB (c35 has ~500 GiB FSDAX)
export FitCache_NVME_CAPACITY=$((500 * 1024 * 1024 * 1024))   # 500 GiB
export BBPATH=$FitCache_NVME_PATH

export FitCache_DATA_DIR=/mnt/beegfs/ghu4/hvac/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440

# Cross-job mode: pick from caller (FitCache_CROSS_JOB env). Default 0
# for the multi-node single-job baseline.
export FitCache_CROSS_JOB=${FitCache_CROSS_JOB:-0}
if [ "$FitCache_CROSS_JOB" = "1" ]; then
    export FitCache_CLUSTER_REGISTRY_DIR=${FitCache_CLUSTER_REGISTRY_DIR:-/mnt/beegfs/ghu4/fitcachepp_registry_multinode}
    mkdir -p "$FitCache_CLUSTER_REGISTRY_DIR"
fi

export RESULTS_DIR=/home/ghu4/hvac/FitCachePP/benchmarks/results/multinode_baseline
mkdir -p "$RESULTS_DIR"
export FitCache_PORTS_CFG_DIR=$RESULTS_DIR
cd "$RESULTS_DIR"

# n_train: caller can override via FITPP_N_TRAIN. Default 61440 (the IPDPS
# full dataset — apples-to-IPDPS-FitCache wall-clock). Use 8192 for a
# faster-iterating Phase A.1 run.
export FITPP_N_TRAIN=${FITPP_N_TRAIN:-61440}
echo "FITPP_N_TRAIN=$FITPP_N_TRAIN  (IPDPS used 61440)"

# ---------------- Pre-create cache dirs on each PM node ----------------
# Skip entirely in Pure_CF mode — no FitCache servers will run, no cache
# tiers needed. Pure_CF reads BeeGFS direct from the GPU client.
if [ "${FITPP_PURE_CF:-0}" != "1" ]; then
    for pm in "${PM_NODES[@]}"; do
        srun -N1 -n1 -w "$pm" --jobid=$SLURM_JOB_ID \
            bash -c "mkdir -p $FitCache_DRAM_PATH $FitCache_NVME_PATH $FitCache_PMEM_PATH; \
                     if [ \"\${FITPP_PURGE_CACHE:-0}\" = \"1\" ]; then \
                         find $FitCache_DRAM_PATH -mindepth 1 -delete 2>/dev/null; \
                         find $FitCache_NVME_PATH -mindepth 1 -delete 2>/dev/null; \
                         find $FitCache_PMEM_PATH -mindepth 1 -delete 2>/dev/null; \
                     fi" || echo "[warn] pre-create on $pm failed"
    done
fi

# ---------------- Launch FitCache servers on PM node(s) ----------------
# Pure_CF mode skips this entirely — no servers, no LD_PRELOAD, training
# reads BeeGFS directly. The "Pure_CF" column of the comparison table.
SERVER_BIN=/home/ghu4/hvac/FitCachePP/build/src/fitcache_server
SERVER_PIDS=()
GLOBAL_SERVER_ID=0
BASE_PORT=5555

if [ "${FITPP_PURE_CF:-0}" = "1" ]; then
    echo "[$(date '+%H:%M:%S')] FITPP_PURE_CF=1: skipping FitCache server launch (Pure_CF baseline)"
else
for pm in "${PM_NODES[@]}"; do
    echo "[$(date '+%H:%M:%S')] starting $SERVERS_PER_PM_NODE servers on $pm (procs $GLOBAL_SERVER_ID..$((GLOBAL_SERVER_ID + SERVERS_PER_PM_NODE - 1)))"
    # Use ONE srun call with -n${SERVERS_PER_PM_NODE} so SLURM auto-assigns
    # SLURM_PROCID=0,1,2,3 across the tasks. Four parallel srun -n1 calls
    # serialize on the SLURM step ("Requested nodes are busy") and only the
    # first task actually runs — see cancelled 221643 for the failure mode.
    # FitCache_SERVER_PORT unset → Mercury picks ephemeral ports (the actual
    # port is captured in .ports.cfg via HG_Addr_to_string).
    srun --jobid=$SLURM_JOB_ID -N1 -n${SERVERS_PER_PM_NODE} -w "$pm" \
        --export=ALL \
        "$SERVER_BIN" "$FitCache_SERVER_COUNT" \
        > "$RESULTS_DIR/server_${SLURM_JOB_ID}_${pm}.log" 2>&1 &
    SERVER_PIDS+=($!)
    GLOBAL_SERVER_ID=$((GLOBAL_SERVER_ID + SERVERS_PER_PM_NODE))
done

# Wait for .ports.cfg to populate (one entry per server).
for i in $(seq 1 30); do
    n=$(grep -c '' "$RESULTS_DIR/.ports.cfg.$SLURM_JOB_ID" 2>/dev/null || echo 0)
    [ "$n" -ge "$TOTAL_SERVERS" ] && { echo "[$(date '+%H:%M:%S')] all $TOTAL_SERVERS server endpoints registered"; break; }
    sleep 2
done
fi  # end FITPP_PURE_CF guard

# ---------------- Launch Horovod training on GPU node(s) ----------------
echo "[$(date '+%H:%M:%S')] horovodrun -np $TOTAL_GPUS -H $HOROVOD_HOSTLIST"
horovodrun -np "$TOTAL_GPUS" -H "$HOROVOD_HOSTLIST" \
    /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/command_CF_FITPP.sh \
    2>&1 | tee "$RESULTS_DIR/horovodrun_${SLURM_JOB_ID}.log"
HOROVOD_RC=${PIPESTATUS[0]}

# ---------------- Cleanup ----------------
echo "[$(date '+%H:%M:%S')] tearing down servers"
for pid in "${SERVER_PIDS[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
sleep 3
for pid in "${SERVER_PIDS[@]}"; do kill -9 "$pid" 2>/dev/null || true; done

# ---------------- Engagement self-check ----------------
OPENS_TOTAL=0
for f in "$RESULTS_DIR"/fitcache_server_log.*.0; do
    [ -f "$f" ] || continue
    n=$(grep -c 'Open RPC: requested path' "$f" 2>/dev/null || echo 0)
    OPENS_TOTAL=$((OPENS_TOTAL + n))
done
# Per-PM-node cached file count.
CACHED_TOTAL=0
for pm in "${PM_NODES[@]}"; do
    n=$(srun -N1 -n1 -w "$pm" --jobid=$SLURM_JOB_ID bash -c \
        "find $FitCache_DRAM_PATH $FitCache_PMEM_PATH $FitCache_NVME_PATH -type f ! -name '*.meta' 2>/dev/null | wc -l" 2>/dev/null)
    CACHED_TOTAL=$((CACHED_TOTAL + ${n:-0}))
done
echo "[$(date '+%H:%M:%S')] engagement: $OPENS_TOTAL Open RPCs, $CACHED_TOTAL cached files across PM nodes"
if [ "$OPENS_TOTAL" -eq 0 ] && [ "$CACHED_TOTAL" -eq 0 ]; then
    echo "[$(date '+%H:%M:%S')] !!! WARNING !!! FitCache was NOT engaged this run."
fi

echo "[$(date '+%H:%M:%S')] DONE multinode (job $SLURM_JOB_ID, horovod_rc=$HOROVOD_RC)"
exit $HOROVOD_RC
