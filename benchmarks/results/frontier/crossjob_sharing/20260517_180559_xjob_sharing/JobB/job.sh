#!/bin/bash
#SBATCH -J xjob_JobB
#SBATCH -t 00:30:00
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH --account=gen008
#SBATCH -q hackathon
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/crossjob_sharing/20260517_180559_xjob_sharing/JobB/JobB-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP

set -euo pipefail
cd $FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

# Stagger so Job A populates its cache before Job B starts peer_lookups
if [ "180" -gt 0 ]; then
    echo "[JobB] sleeping 180s to let the other job warm its cache"
    sleep 180
fi

RESULTS_DIR="/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/crossjob_sharing/20260517_180559_xjob_sharing/JobB"
mkdir -p "$RESULTS_DIR"
cd "$RESULTS_DIR"

export BBPATH=/tmp
export FitCache_DATA_DIR="/lustre/orion/gen008/proj-shared/ghu4/data/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2"
# Distinct /tmp paths per TAG — JobB's local cache starts empty so any
# speedup we measure is unambiguously from peer-cache reuse via the
# shared cluster registry, not local-cache reuse.
export FitCache_DRAM_PATH=/tmp/xjob_JobB_20260517_180559_xjob_sharing_dram
export FitCache_NVME_PATH=/tmp/xjob_JobB_20260517_180559_xjob_sharing_nvme
export FitCache_DRAM_CAPACITY=$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="$RESULTS_DIR"
export FitCache_SERVER_COUNT=2
# Enable cross-job sharing
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR="/lustre/orion/gen008/proj-shared/ghu4/fitcachepp_registry/crossjob_sharing/20260517_180559_xjob_sharing"
# Skip the recursive_directory_iterator manifest scan in subscribe_self_to_local_dataset.
# At 524288 cosmoflow files × 8 ranks, the scan adds ~9 min to constructor startup
# and the resulting manifest_hash is not load-bearing for our sharing test
# (both jobs name the same root path, so root_path_hash alone suffices to match
# their subscriptions in the cluster registry).
export FITPP_SKIP_MANIFEST_SCAN=1
# Peer-death recovery knobs:
#  - Shorten heartbeat from default 30s to 10s so dead-peer detection
#    (3x heartbeat = 30s) lines up with the 10s ms_read timeout.
#  - ms_read pthread_cond_timedwait timeout: when an in-flight read RPC
#    targets a now-dead peer, fall back to __real_pread on the local PFS fd.
export FitCache_HEARTBEAT_SEC=10
export FitCache_MS_READ_TIMEOUT_SEC=10
mkdir -p "$FitCache_DRAM_PATH" "$FitCache_NVME_PATH"

# Frontier MIOpen / TF / horovod knobs (same as headline cosmoflow)
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_JobB_$SLURM_PROCID
mkdir -p $MIOPEN_USER_DB_PATH
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3
export HOROVOD_STALL_CHECK_TIME_SECONDS=600
export HOROVOD_STALL_SHUTDOWN_TIME_SECONDS=0
export HOROVOD_CYCLE_TIME=5

# Use the same seed for both jobs so they access overlapping file subsets
export FITPP_SEED=0

echo "[JobB] nodes=1  total_servers=$FitCache_SERVER_COUNT  cross_job=1  registry=/lustre/orion/gen008/proj-shared/ghu4/fitcachepp_registry/crossjob_sharing/20260517_180559_xjob_sharing"
echo "[JobB] DRAM=$FitCache_DRAM_PATH (local — starts empty by design)"

# Spawn FitCache servers (2/node)
echo "[JobB] launching servers via srun"
srun -N 1 -n 2 --ntasks-per-node=2 --cpus-per-task=1 --cpu-bind=cores \
     "$FITPP_SERVER_BIN" 2 \
     > "$RESULTS_DIR/server_${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=$!
sleep 15

# Training wrapper with LD_PRELOAD
WRAPPER="$RESULTS_DIR/train_wrapper.sh"
cat > "$WRAPPER" <<'WEOF'
#!/bin/bash
cd $FITPP_COSMOFLOW_DIR
LD_PRELOAD="$FITPP_CLIENT_LIB" $FITPP_PYTHON_TF \
    $FITPP_COSMOFLOW_DIR/train.py -d \
    --data-dir "$FitCache_DATA_DIR" \
    --n-train 8192 \
    --n-epochs 2
WEOF
chmod +x "$WRAPPER"

echo "[JobB] launching training: 8 GPUs"
START=$SECONDS
srun -N 1 -c4 --gpus-per-node=8 --ntasks-per-gpu=1 --cpu-bind=cores \
     "$WRAPPER" 2>&1 | tee "$RESULTS_DIR/train_${SLURM_JOB_ID}.log"
TRAIN_RC=${PIPESTATUS[0]}
END=$SECONDS
echo "[JobB] training wall=$((END - START))s rc=$TRAIN_RC"

# Teardown
kill -TERM $SERVER_SRUN_PID 2>/dev/null || true
sleep 5

OPEN_RPC=$(grep -cE "Open RPC: requested path" $RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
PEER_LOOKUP_HANDLED=$(grep -cE "peer_lookup.*HAS|peer_lookup.*NOT HAS" $RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
PEER_HAS_YES=$(grep -cE "peer_lookup.*HAS local|peer_lookup.*HAS remote" $RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
REDIRECTS=$(grep -cE "Open RPC redirect" $RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
echo "----- JobB summary -----"
echo "  Training wall:        $((END - START))s"
echo "  Open RPCs:            $OPEN_RPC"
echo "  peer_lookup handled:  $PEER_LOOKUP_HANDLED"
echo "  peer_lookup has_yes:  $PEER_HAS_YES"
echo "  opens_redirect_to_peer: $REDIRECTS"
