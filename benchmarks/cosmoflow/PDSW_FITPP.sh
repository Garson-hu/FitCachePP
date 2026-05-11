#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -t 1-00:00:00
#SBATCH -J FitCachePP
#SBATCH --mail-type=END
#SBATCH --mail-user=ghu4@ncsu.edu
#SBATCH -o /home/ghu4/hvac/FitCachePP/benchmarks/results/single_job_baseline/FitCachePP-%j.out
#
# Single-job FitCache++ baseline benchmark (CosmoFlow on cosmoUniverse-mini).
# Runs FitCache++ in single-job mode (FitCache_CROSS_JOB=0). Wall-clock and
# per-batch I/O numbers should match the IPDPS PDSW_FIT.sh runs in
# logs/pdsw/ — defends the zero-regression-vs-IPDPS-single-job claim.
#
# Adapted from /home/ghu4/hvac/benchmark/cosmoflow-benchmark-master/PDSW_FIT.sh
# (the IPDPS MS_READ-based variant). Differences from PDSW_FIT.sh:
#   - Server binary: /home/ghu4/hvac/FitCachePP/build/src/fitcache_server
#     (was /mnt/beegfs/ghu4/hvac/GHU_HVAC/build/src/hvac_server)
#   - Client lib (in command_CF_FITPP.sh): libfitcache_client.so from
#     FitCache++ build (was MS_READ libhvac_client.so)
#   - Env-var prefix: FitCache_* (was HVAC_*)
#   - Cross-job mode OFF for this baseline run; the cross-job experiments
#     live in PDSW_FITPP_two_job_*.sh
#
# Server count = 4, all on the single client/server node. Matches the
# 4-servers-per-node default for non-trivial datasets.

# !!! Pick a single rtx4060ti16g node (sbatch will fill SLURM_NODELIST).
#     Override -w via sbatch CLI if you want a specific node, e.g.
#     sbatch -w c54 PDSW_FITPP.sh

# Server topology: 4 FitCache++ servers + 1 client GPU on the same node.
SERVER_NODES_DEFAULT="$(scontrol show hostnames $SLURM_JOB_NODELIST | head -1)"
SERVER_NODES="${SERVER_NODES:-$SERVER_NODES_DEFAULT}"
SERVERS_PER_NODE="4"
CLIENT_NODES="${CLIENT_NODES:-$SERVER_NODES_DEFAULT}"
GPUS_PER_NODE=1
export FitCache_SERVER_COUNT=4

# Parse to arrays
read -a SERVER_NODES_ARR  <<< "$SERVER_NODES"
read -a SERVERS_PER_NODE_ARR <<< "$SERVERS_PER_NODE"
read -a CLIENT_NODES_ARR  <<< "$CLIENT_NODES"

# Sanity
[ ${#SERVER_NODES_ARR[@]} -eq 0 ]                           && { echo "ERROR: SERVER_NODES empty"; exit 1; }
[ ${#SERVER_NODES_ARR[@]} -ne ${#SERVERS_PER_NODE_ARR[@]} ] && { echo "ERROR: SERVERS_PER_NODE size mismatch"; exit 1; }

CALC_TOTAL=0
for n in "${SERVERS_PER_NODE_ARR[@]}"; do CALC_TOTAL=$((CALC_TOTAL + n)); done
[ "$CALC_TOTAL" -ne "$FitCache_SERVER_COUNT" ] && { echo "ERROR: FitCache_SERVER_COUNT ($FitCache_SERVER_COUNT) != sum-of-SERVERS_PER_NODE ($CALC_TOTAL)"; exit 1; }

# Build Horovod host list
TOTAL_GPUS=$(( ${#CLIENT_NODES_ARR[@]} * GPUS_PER_NODE ))
HOROVOD_HOSTLIST=""
for node in "${CLIENT_NODES_ARR[@]}"; do
    HOROVOD_HOSTLIST+="${node}:${GPUS_PER_NODE},"
done
HOROVOD_HOSTLIST=${HOROVOD_HOSTLIST%,}

# Mercury / log4c env (mirrors the build env)
export FitCache_LOG_LEVEL=500
export RDMAV_FORK_SAFE=1
export VERBS_LOG_LEVEL=4
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/rlibrary/miniconda3/envs/hvac_tf/bin:/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH

# Tier paths + capacity. NVMe only here (rtx4060ti16g nodes don't have PMem;
# the three-tier eval lives in PDSW_FITPP_three_tier.sh and runs on c35).
export FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_train_cache_dram
export FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_train_cache_nvme
export FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))   # 100 GB
export FitCache_NVME_CAPACITY=$((500 * 1024 * 1024 * 1024))   # 500 GB
export FitCache_DATA_DIR=/mnt/beegfs/ghu4/hvac/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440/train/

export BBPATH=$FitCache_NVME_PATH

# Single-job baseline: cross-job OFF. Servers behave exactly like IPDPS.
export FitCache_CROSS_JOB=0

# Make sure the result dir exists
RESULTS_DIR=/home/ghu4/hvac/FitCachePP/benchmarks/results/single_job_baseline
mkdir -p "$RESULTS_DIR"

# ------------------- Launch FitCache++ servers -------------------
echo "Starting FitCache++ servers..."
SERVER_BIN=/home/ghu4/hvac/FitCachePP/build/src/fitcache_server
SERVER_PIDS=()
BASE_PORT=5555
GLOBAL_SERVER_ID=0

for idx in "${!SERVER_NODES_ARR[@]}"; do
    NODE=${SERVER_NODES_ARR[$idx]}
    SERVERS_FOR_THIS_NODE=${SERVERS_PER_NODE_ARR[$idx]}
    [ "$SERVERS_FOR_THIS_NODE" -le 0 ] && continue

    # Pre-create per-server cache dirs so multiple servers on the same node
    # don't race on mkdir.
    mkdir -p "$FitCache_DRAM_PATH" "$FitCache_NVME_PATH"

    echo "Starting $SERVERS_FOR_THIS_NODE servers on $NODE"
    for local_idx in $(seq 0 $((SERVERS_FOR_THIS_NODE - 1))); do
        PORT=$((BASE_PORT + GLOBAL_SERVER_ID))
        echo "  Server ID=$GLOBAL_SERVER_ID  $NODE:$PORT"
        SLURM_PROCID=$GLOBAL_SERVER_ID \
        FitCache_SERVER_PORT=$PORT \
            mpirun -N 1 -host "$NODE" "$SERVER_BIN" "$FitCache_SERVER_COUNT" \
            > "$RESULTS_DIR/server_${SLURM_JOB_ID}_id${GLOBAL_SERVER_ID}.log" 2>&1 &
        SERVER_PIDS+=($!)
        GLOBAL_SERVER_ID=$((GLOBAL_SERVER_ID + 1))
    done
done

# Give the servers a few seconds to register and write .ports.cfg.${SLURM_JOBID}
sleep 5

# ------------------- Launch CosmoFlow training -------------------
if [ "$TOTAL_GPUS" -gt 0 ]; then
    echo "Launching Horovod training on $TOTAL_GPUS GPUs (hostlist: $HOROVOD_HOSTLIST)"
    horovodrun -np "$TOTAL_GPUS" -H "$HOROVOD_HOSTLIST" \
        /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/command_CF_FITPP.sh
else
    echo "WARNING: TOTAL_GPUS=0; not launching training"
fi

# ------------------- Cleanup -------------------
echo "Training finished; tearing down FitCache++ servers"
for pid in "${SERVER_PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
done
sleep 2
for pid in "${SERVER_PIDS[@]}"; do
    kill -9 "$pid" 2>/dev/null || true
done

echo "DONE single-job FitCache++ baseline (job $SLURM_JOB_ID)"
