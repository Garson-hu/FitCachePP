#!/bin/bash
# Cross-job sharing proof at n=8192 / 1 node × 8 GPU.
#
# Two FitCachePP jobs in series (Job B depends on Job A's completion):
#   - Both with same FITPP_SEED + same n_train → identical file subset.
#   - Different /tmp DRAM/NVMe paths so Job B's LOCAL cache starts empty.
#   - Shared FitCache_CLUSTER_REGISTRY_DIR on PFS so Job B's servers can
#     discover Job A's still-cached files via peer_lookup.
#   - Job A's servers stay alive across both jobs? NO — sbatch jobs are
#     isolated, Job A's servers die at the end. Cross-job sharing here
#     relies on (1) Option 1 (PFS presence index — durable) and/or
#     (2) Option 2 (in-memory remote_presence_map — only useful for
#     concurrent jobs, dies with the server).
#
# So the load-bearing sharing mechanism for this sequential test is
# **Option 1 (PFS presence index)** + sibling-cache-refresh: Job B's
# servers, on startup, scan presence/ on PFS and any sibling tier dirs
# they have access to.
#
# Job B's local DRAM/NVMe paths are DIFFERENT from Job A's, so Job B's
# servers can't restore from Job A's local /tmp via sidecar — those /tmp
# dirs are private to Job A's node. The only sharing channel left in the
# sequential pattern is peer_lookup → Option 1 presence index returning
# Job A's serve_addr — but Job A's servers are dead, so peer_lookup will
# get HG_Addr_lookup failures, fall through to PFS, and the run becomes
# equivalent to a fresh cold epoch on Job B's node.
#
# To make the test load-bearing, we run the two jobs CONCURRENTLY but with
# JobB starting ~30s after Job A, so Job A's servers are still alive when
# Job B's clients issue peer_lookups. Job B's local cache is empty (different
# /tmp paths). If Job B's epoch-1 wall ≈ Job A's WARM epoch wall, peer
# sharing is working.
#
# Concurrent on the same node is fine: both jobs allocate 8 GPUs and 32 CPU
# cores; ./tmp/ is local to each node. We'd need two separate Frontier nodes
# OR overlapping cores. SLURM doesn't let two jobs share a node easily.
# So: two nodes, one each, talking via shared PFS registry.
#
# Usage:
#   bash scripts/frontier/frontier_cosmoflow_crossjob_sharing.sh

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_TRAIN="${FITPP_N_TRAIN:-8192}"
N_EPOCHS="${FITPP_N_EPOCHS:-2}"
WALLTIME="${WALLTIME:-00:30:00}"
QOS="${QOS:-hackathon}"
SEED="${FITPP_SEED:-0}"
# Servers per node — raised from 2 to 4 (2026-05-17). With 2 servers/node
# the n=32768 single-server Mercury progress thread serializes incoming RPC
# handlers on Lustre opens under MDS contention and the server falls silent
# after ~280 opens. Four servers spread the Mercury queue across four
# progress threads, with each owning a 1/4 slice of the path hashring.
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"

# Stagger Job B's start so A has time to FULLY WARM its cache before B
# starts issuing peer_lookups. 30s wasn't long enough on the prior run
# (4602008 series) — JobA's Epoch 1 cold takes ~135s, so JobA needs
# >135s + a bit more before its cache is fully populated. Default 180s
# = enough time for JobA to finish Epoch 1 cold + start serving warm.
JOBB_DELAY_SEC="${JOBB_DELAY_SEC:-180}"

COSMOFLOW_DATA="${COSMOFLOW_DATA:-${FITPP_PFS_DATA_ROOT}/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2}"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_xjob_sharing
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/crossjob_sharing/${RUN_TAG}"
REGISTRY_DIR="${FITPP_PFS_REGISTRY_ROOT}/crossjob_sharing/${RUN_TAG}"
mkdir -p "$ROOT_DIR/JobA" "$ROOT_DIR/JobB" "$REGISTRY_DIR"

echo "[driver] RUN_TAG=$RUN_TAG"
echo "[driver] root: $ROOT_DIR"
echo "[driver] registry: $REGISTRY_DIR"
echo "[driver] n_train=$N_TRAIN  n_epochs=$N_EPOCHS  seed=$SEED"

# Build the sbatch body. The two jobs share most env; differ only in:
#   - JOB_TAG (JobA / JobB)
#   - JobB has a `sleep $JOBB_DELAY_SEC` at the very start
#   - cache subdir (so /tmp paths are distinct)
submit_job() {
    local TAG="$1" DELAY_SEC="$2"
    local JOB_DIR="$ROOT_DIR/${TAG}"
    local QOS_LINE=""
    [ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

    cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J xjob_${TAG}
#SBATCH -t $WALLTIME
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/${TAG}-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

# Stagger so Job A populates its cache before Job B starts peer_lookups
if [ "$DELAY_SEC" -gt 0 ]; then
    echo "[${TAG}] sleeping ${DELAY_SEC}s to let the other job warm its cache"
    sleep $DELAY_SEC
fi

RESULTS_DIR="$JOB_DIR"
mkdir -p "\$RESULTS_DIR"
cd "\$RESULTS_DIR"

export BBPATH=/tmp
export FitCache_DATA_DIR="$COSMOFLOW_DATA"
# Distinct /tmp paths per TAG — JobB's local cache starts empty so any
# speedup we measure is unambiguously from peer-cache reuse via the
# shared cluster registry, not local-cache reuse.
export FitCache_DRAM_PATH=/tmp/xjob_${TAG}_${RUN_TAG}_dram
export FitCache_NVME_PATH=/tmp/xjob_${TAG}_${RUN_TAG}_nvme
export FitCache_DRAM_CAPACITY=\$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$SERVERS_PER_NODE
# Enable cross-job sharing
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR="$REGISTRY_DIR"
# Skip the recursive_directory_iterator manifest scan in subscribe_self_to_local_dataset.
# At 524288 cosmoflow files × 8 ranks, the scan adds ~9 min to constructor startup
# and the resulting manifest_hash is not load-bearing for our sharing test
# (both jobs name the same root path, so root_path_hash alone suffices to match
# their subscriptions in the cluster registry).
export FITPP_SKIP_MANIFEST_SCAN=1
# Heartbeat shortened to 10s so dead-peer detection (3x heartbeat = 30s)
# lines up with cross-job recovery expectations.
export FitCache_HEARTBEAT_SEC=10
# Profiling: dump FitCache_TIMING per-tag histogram on client exit so we can
# break down ms_read overhead by code path (bypass_pfs vs peer_redirect_total
# vs hrw_normal_total) and quantify Mercury bulk-transfer / redirect costs.
export FITPP_TIMING_DUMP_ON_EXIT=1
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

# Frontier MIOpen / TF / horovod knobs (same as headline cosmoflow)
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_${TAG}_\$SLURM_PROCID
mkdir -p \$MIOPEN_USER_DB_PATH
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3
export HOROVOD_STALL_CHECK_TIME_SECONDS=600
export HOROVOD_STALL_SHUTDOWN_TIME_SECONDS=0
export HOROVOD_CYCLE_TIME=5

# Use the same seed for both jobs so they access overlapping file subsets
export FITPP_SEED=$SEED

echo "[${TAG}] nodes=1  total_servers=\$FitCache_SERVER_COUNT  cross_job=1  registry=$REGISTRY_DIR"
echo "[${TAG}] DRAM=\$FitCache_DRAM_PATH (local — starts empty by design)"

# Spawn FitCache servers (N/node; default 4 — see SERVERS_PER_NODE above).
echo "[${TAG}] launching $SERVERS_PER_NODE servers via srun"
srun -N 1 -n $SERVERS_PER_NODE --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $SERVERS_PER_NODE \\
     > "\$RESULTS_DIR/server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=\$!
sleep 15

# Training wrapper with LD_PRELOAD
WRAPPER="\$RESULTS_DIR/train_wrapper.sh"
cat > "\$WRAPPER" <<'WEOF'
#!/bin/bash
cd \$FITPP_COSMOFLOW_DIR
LD_PRELOAD="\$FITPP_CLIENT_LIB" \$FITPP_PYTHON_TF \\
    \$FITPP_COSMOFLOW_DIR/train.py -d \\
    --data-dir "\$FitCache_DATA_DIR" \\
    --n-train $N_TRAIN \\
    --n-epochs $N_EPOCHS
WEOF
chmod +x "\$WRAPPER"

echo "[${TAG}] launching training: 8 GPUs"
START=\$SECONDS
srun -N 1 -c4 --gpus-per-node=8 --ntasks-per-gpu=1 --cpu-bind=cores \\
     "\$WRAPPER" 2>&1 | tee "\$RESULTS_DIR/train_\${SLURM_JOB_ID}.log"
TRAIN_RC=\${PIPESTATUS[0]}
END=\$SECONDS
echo "[${TAG}] training wall=\$((END - START))s rc=\$TRAIN_RC"

# Teardown
kill -TERM \$SERVER_SRUN_PID 2>/dev/null || true
sleep 5

OPEN_RPC=\$(grep -cE "Open RPC: requested path" \$RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
PEER_LOOKUP_HANDLED=\$(grep -cE "peer_lookup.*HAS|peer_lookup.*NOT HAS" \$RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
PEER_HAS_YES=\$(grep -cE "peer_lookup.*HAS local|peer_lookup.*HAS remote" \$RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
REDIRECTS=\$(grep -cE "Open RPC redirect" \$RESULTS_DIR/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
echo "----- ${TAG} summary -----"
echo "  Training wall:        \$((END - START))s"
echo "  Open RPCs:            \$OPEN_RPC"
echo "  peer_lookup handled:  \$PEER_LOOKUP_HANDLED"
echo "  peer_lookup has_yes:  \$PEER_HAS_YES"
echo "  opens_redirect_to_peer: \$REDIRECTS"
EOF
    chmod +x "$JOB_DIR/job.sh"
    sbatch --parsable "$JOB_DIR/job.sh"
}

JOB_A=$(submit_job JobA 0)
JOB_B=$(submit_job JobB $JOBB_DELAY_SEC)
echo "JobA: $JOB_A -> $ROOT_DIR/JobA/"
echo "JobB: $JOB_B -> $ROOT_DIR/JobB/  (delayed ${JOBB_DELAY_SEC}s)"

cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
job_a=$JOB_A
job_b=$JOB_B
n_train=$N_TRAIN
n_epochs=$N_EPOCHS
seed=$SEED
jobB_delay_sec=$JOBB_DELAY_SEC
registry=$REGISTRY_DIR
qos=$QOS
walltime=$WALLTIME
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
