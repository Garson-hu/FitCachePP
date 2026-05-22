#!/bin/bash
# Frontier cross-job sharing test with a CONTROLLED warm provider.
#
# Difference from frontier_cosmoflow_crossjob_sharing.sh:
#   - The producer training job runs to completion (cold + warm epochs),
#     then SLEEPS $KEEPALIVE_SEC seconds, keeping its FitCache servers
#     + populated /tmp cache alive. This isolates "consumer reads from
#     a fully-warm peer cache" from the timing variance of the prior
#     concurrent setup.
#   - The consumer sleeps $JOBB_DELAY_SEC before starting training so
#     the producer's first epoch (cold) finishes first and the cache
#     is fully populated before any consumer RPC fires.
#   - The consumer's local /tmp cache is empty by design, so any
#     speedup the consumer gets is unambiguously from cross-job sharing.
#
# Goal: consumer cold-epoch wall approaches the WARM-epoch wall.
# At n=32768 the warm-epoch wall is ~285s; if the consumer cold drops
# from ~352s (single-job mean) toward 285s, the cross-job sharing
# claim is strong (not just −14s of variance-bounded savings).
#
# Usage:
#   bash scripts/frontier/frontier_cosmoflow_xjob_warmprovider.sh
#
# Tunables (env):
#   FITPP_N_TRAIN          default 32768
#   FITPP_N_EPOCHS         default 2
#   JOBB_DELAY_SEC         default 600  (wait long enough that producer Epoch 1 finishes)
#   KEEPALIVE_SEC          default 900  (producer keeps cache+servers alive after training)
#   WALLTIME               default 00:45:00
#   QOS                    default hackathon
#   SERVERS_PER_NODE       default 4

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_TRAIN="${FITPP_N_TRAIN:-32768}"
N_EPOCHS="${FITPP_N_EPOCHS:-2}"
WALLTIME="${WALLTIME:-00:45:00}"
QOS="${QOS:-hackathon}"
SEED="${FITPP_SEED:-0}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
JOBB_DELAY_SEC="${JOBB_DELAY_SEC:-600}"
KEEPALIVE_SEC="${KEEPALIVE_SEC:-900}"

COSMOFLOW_DATA="${COSMOFLOW_DATA:-${FITPP_PFS_DATA_ROOT}/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2}"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_xjob_warmprovider
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/xjob_warmprovider/${RUN_TAG}"
REGISTRY_DIR="${FITPP_PFS_REGISTRY_ROOT}/xjob_warmprovider/${RUN_TAG}"
mkdir -p "$ROOT_DIR/Producer" "$ROOT_DIR/Consumer" "$REGISTRY_DIR"

echo "[driver] RUN_TAG=$RUN_TAG"
echo "[driver] root: $ROOT_DIR"
echo "[driver] registry: $REGISTRY_DIR"
echo "[driver] n_train=$N_TRAIN  n_epochs=$N_EPOCHS  seed=$SEED"
echo "[driver] producer-keepalive=${KEEPALIVE_SEC}s  consumer-delay=${JOBB_DELAY_SEC}s"

# The two jobs share most env; differ in role:
#   - TAG = Producer | Consumer
#   - Producer trains then sleeps KEEPALIVE_SEC (keeps servers + cache alive)
#   - Consumer sleeps JOBB_DELAY_SEC first, then trains
#   - Distinct /tmp paths so consumer's local cache starts empty
submit_job() {
    local TAG="$1"
    local JOB_DIR="$ROOT_DIR/${TAG}"
    local QOS_LINE=""
    [ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

    # Role-specific control flags
    local PRE_TRAIN_SLEEP=0
    local POST_TRAIN_SLEEP=0
    if [ "$TAG" = "Consumer" ]; then PRE_TRAIN_SLEEP=$JOBB_DELAY_SEC; fi
    if [ "$TAG" = "Producer" ]; then POST_TRAIN_SLEEP=$KEEPALIVE_SEC; fi

    cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J xjob_wp_${TAG}
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

RESULTS_DIR="$JOB_DIR"
mkdir -p "\$RESULTS_DIR"
cd "\$RESULTS_DIR"

export BBPATH=/tmp
export FitCache_DATA_DIR="$COSMOFLOW_DATA"
# Distinct /tmp paths per TAG — Consumer's local cache starts empty so any
# speedup we measure is unambiguously from peer-cache reuse via the
# shared cluster registry, not local-cache reuse.
export FitCache_DRAM_PATH=/tmp/xjob_wp_${TAG}_${RUN_TAG}_dram
export FitCache_NVME_PATH=/tmp/xjob_wp_${TAG}_${RUN_TAG}_nvme
export FitCache_DRAM_CAPACITY=\$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$SERVERS_PER_NODE
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR="$REGISTRY_DIR"
export FITPP_SKIP_MANIFEST_SCAN=1
export FitCache_HEARTBEAT_SEC=10
export FITPP_TIMING_DUMP_ON_EXIT=1
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

# Frontier MIOpen / TF / Horovod knobs (same as headline cosmoflow)
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

# Same seed in both jobs so they request overlapping file subsets
export FITPP_SEED=$SEED

echo "[${TAG}] nodes=1  total_servers=\$FitCache_SERVER_COUNT  cross_job=1  registry=$REGISTRY_DIR"
echo "[${TAG}] DRAM=\$FitCache_DRAM_PATH"
echo "[${TAG}] role: $TAG  pre_train_sleep=${PRE_TRAIN_SLEEP}s  post_train_sleep=${POST_TRAIN_SLEEP}s"

# Spawn FitCache servers — these must outlive the training step on the
# producer side so the consumer's lookups land on a live cache.
echo "[${TAG}] launching $SERVERS_PER_NODE servers via srun"
srun -N 1 -n $SERVERS_PER_NODE --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $SERVERS_PER_NODE \\
     > "\$RESULTS_DIR/server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=\$!
sleep 15

# Consumer waits until producer has populated its cache. Done AFTER the
# server srun so the consumer's servers register in the registry promptly
# (so the producer's clients see all 8 slots), but BEFORE the consumer
# fires any training-side opens.
if [ "$PRE_TRAIN_SLEEP" -gt 0 ]; then
    echo "[${TAG}] pre-training sleep ${PRE_TRAIN_SLEEP}s (waiting for producer cache to warm)"
    sleep $PRE_TRAIN_SLEEP
fi

# Training wrapper with LD_PRELOAD
WRAPPER="\$RESULTS_DIR/train_wrapper.sh"
cat > "\$WRAPPER" <<'WEOF'
#!/bin/bash
cd \$FITPP_COSMOFLOW_DIR
LD_PRELOAD="\$FITPP_CLIENT_LIB" \$FITPP_PYTHON_TF \\
    \$FITPP_COSMOFLOW_DIR/train.py -d \\
    --data-dir "\$FitCache_DATA_DIR" \\
    --n-train $N_TRAIN \\
    --n-valid 1024 \\
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

# Producer holds the cache alive until the consumer is well into its
# training so consumer's reads still hit a warm peer cache. The
# 4-rank-server srun (PID \$SERVER_SRUN_PID) stays alive during this sleep.
if [ "$POST_TRAIN_SLEEP" -gt 0 ]; then
    echo "[${TAG}] post-training keepalive sleep ${POST_TRAIN_SLEEP}s"
    sleep $POST_TRAIN_SLEEP
fi

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
echo "  opens_redirect:       \$REDIRECTS"
EOF
    chmod +x "$JOB_DIR/job.sh"
    sbatch --parsable "$JOB_DIR/job.sh"
}

JOB_P=$(submit_job Producer)
JOB_C=$(submit_job Consumer)
echo "Producer: $JOB_P -> $ROOT_DIR/Producer/"
echo "Consumer: $JOB_C -> $ROOT_DIR/Consumer/  (sleeps ${JOBB_DELAY_SEC}s before training)"

cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
producer_job=$JOB_P
consumer_job=$JOB_C
n_train=$N_TRAIN
n_epochs=$N_EPOCHS
seed=$SEED
servers_per_node=$SERVERS_PER_NODE
consumer_delay_sec=$JOBB_DELAY_SEC
producer_keepalive_sec=$KEEPALIVE_SEC
registry=$REGISTRY_DIR
qos=$QOS
walltime=$WALLTIME
hypothesis=consumer.cold_epoch approaches producer.warm_epoch_wall via fully-warm peer cache
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
