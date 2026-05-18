#!/bin/bash
# Phase 2 — Cross-job sharing proof of mechanism.
#
# Submits TWO FitCachePP jobs on DIFFERENT compute nodes, both:
#   - FITPP_SEED=0           (same shuffle = overlapping file subsets)
#   - n_train=8192           (small + known-clean from Phase 1)
#   - FitCache_CROSS_JOB=1   (peer_lookup + cluster registry enabled)
#   - FitCache_CLUSTER_REGISTRY_DIR  on PFS so both jobs see each other
#   - Distinct local /tmp paths (per-PID dirs) so neither job sees the
#     other's local cache; the only way one job can use the other's data
#     is via peer_lookup → redirect_to_peer → remote_read RPC.
#
# Expected signals in cross_job_stats[rank=*] log lines on the SECOND
# job to start:
#   - peer_lookup forwarded  > 0   (the job's local servers asked peers)
#   - peer_lookup has_yes    > 0   (peers answered "yes I have it")
#   - opens_redirect_to_peer > 0   (the job consumed cross-job hits)
#   - peer_lookup_timeout    = 0   (the 2026-05-14 watchdog held)
#
# If those four hold, the cross-job sharing mechanism is end-to-end live.
# Then Phase 2 wall-time comparison: Job-B's cold-epoch wall should be
# closer to Phase-1's warm-epoch (73s) than to Phase-1's cold (135s),
# because most of Job-B's first-epoch opens get served from Job-A's
# warm cache via peer RPC.
#
# Usage:
#   bash scripts/frontier/frontier_phase2_cross_job_proof.sh

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES=1
SERVERS_PER_NODE=2
GPUS_PER_NODE=8
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))
N_TRAIN="${FITPP_N_TRAIN:-8192}"
N_EPOCHS="${FITPP_N_EPOCHS:-2}"
WALLTIME="${WALLTIME:-00:30:00}"
QOS="${QOS:-hackathon}"

COSMOFLOW_DATA="${COSMOFLOW_DATA:-${FITPP_PFS_DATA_ROOT}/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2}"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_phase2_xjob
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/cosmoflow_headline/${RUN_TAG}"
REGISTRY_DIR="${FITPP_PFS_REGISTRY_ROOT}/phase2_xjob/${RUN_TAG}"
mkdir -p "$ROOT_DIR" "$REGISTRY_DIR"

QOS_LINE=""
[ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

submit_side() {
    local SIDE=$1            # JobA or JobB
    local START_DELAY=$2     # seconds Job-B waits before starting training
    local JOB_DIR="$ROOT_DIR/$SIDE"
    mkdir -p "$JOB_DIR"

    cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J cosmoflow_${SIDE}_xjob
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/cosmoflow_${SIDE}-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="$JOB_DIR"
mkdir -p "\$RESULTS_DIR"
cd "\$RESULTS_DIR"

# Local cache per-job-per-PID so Job-B can't see Job-A's local /tmp.
# Cross-job sharing must flow through Mercury peer_lookup, not local FS.
export BBPATH=/tmp
export FitCache_DATA_DIR="$COSMOFLOW_DATA"
export FitCache_DRAM_PATH=/tmp/fitcachepp_${SIDE}_\$SLURM_JOB_ID/dram
export FitCache_NVME_PATH=/tmp/fitcachepp_${SIDE}_\$SLURM_JOB_ID/nvme
export FitCache_DRAM_CAPACITY=\$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$TOTAL_SERVERS

# THE cross-job knob. Pointed at a PFS path so both jobs find each other.
export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR=$REGISTRY_DIR
# Skip the recursive_directory_iterator manifest scan in subscribe_self_to_local_dataset.
# 524288 cosmoflow files × 8 parallel rank scans → ~9 min constructor overhead.
# Both jobs share the same root path, so root_path_hash alone matches in the
# cluster registry; manifest_hash content-divergence detection isn't load-bearing here.
export FITPP_SKIP_MANIFEST_SCAN=1

mkdir -p \$FitCache_DRAM_PATH \$FitCache_NVME_PATH

# Frontier MIOpen / TF / horovod knobs (same as Phase 1)
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_\$SLURM_PROCID
mkdir -p \$MIOPEN_USER_DB_PATH
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3
export HOROVOD_STALL_CHECK_TIME_SECONDS=600
export HOROVOD_STALL_SHUTDOWN_TIME_SECONDS=0

echo "[$SIDE] nodes=\$SLURM_NNODES servers=\$FitCache_SERVER_COUNT gpus=$GPUS_PER_NODE"
echo "[$SIDE] cluster_registry=\$FitCache_CLUSTER_REGISTRY_DIR"
echo "[$SIDE] local_cache_dram=\$FitCache_DRAM_PATH"

# Spawn the local FitCache servers
echo "[$SIDE] launching $TOTAL_SERVERS servers via srun"
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE \\
     --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS \\
     > "\$RESULTS_DIR/server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=\$!
sleep 15

# Stagger Job-B so Job-A has time to warm its cache. The README rationale
# is "Job-B's local cache MUST be clean and B's cold MUST come from A's
# warm via peer_lookup" — that means B must START AFTER A has already
# cached files. The simplest version: B sleeps START_DELAY seconds before
# launching the training command. Job-A's epoch-1 wall at n=8192 is ~135s
# from Phase 1, so 180s for Job-B keeps B's epoch-1 starting AFTER A's
# epoch-1 finished — A has cached ~1024 files by then.
if [ "$SIDE" = "JobB" ] && [ "$START_DELAY" -gt 0 ]; then
    echo "[$SIDE] sleeping ${START_DELAY}s so JobA has cache warmed before JobB starts"
    sleep $START_DELAY
fi

WRAPPER="\$RESULTS_DIR/train_wrapper.sh"
cat > "\$WRAPPER" <<'WEOF'
#!/bin/bash
cd \$FITPP_COSMOFLOW_DIR
LD_PRELOAD=\$FITPP_CLIENT_LIB \$FITPP_PYTHON_TF \\
    \$FITPP_COSMOFLOW_DIR/train.py -d \\
    --data-dir "\$FitCache_DATA_DIR" \\
    --n-train $N_TRAIN \\
    --n-epochs $N_EPOCHS
WEOF
chmod +x "\$WRAPPER"

echo "[$SIDE] launching training: $((N_NODES * GPUS_PER_NODE)) GPUs"
START=\$SECONDS
srun -N $N_NODES -c4 --gpus-per-node=$GPUS_PER_NODE --ntasks-per-gpu=1 \\
     --cpu-bind=cores "\$WRAPPER" 2>&1 | tee "\$RESULTS_DIR/train_\${SLURM_JOB_ID}.log"
TRAIN_RC=\${PIPESTATUS[0]}
END=\$SECONDS
echo "[$SIDE] training wall=\$((END - START))s rc=\$TRAIN_RC"

kill -TERM \$SERVER_SRUN_PID 2>/dev/null || true
sleep 5

echo "----- $SIDE cross_job_stats (final) -----"
for f in \$RESULTS_DIR/fitcache_server_log.*.0; do
    [ -f "\$f" ] || continue
    echo "  \$(basename \$f):"
    grep 'cross_job_stats' "\$f" | tail -2 | sed 's/^/    /'
done
EOF
    chmod +x "$JOB_DIR/job.sh"
    sbatch --parsable "$JOB_DIR/job.sh"
}

JOB_A=$(submit_side JobA 0)
JOB_B=$(submit_side JobB 180)
echo "JobA: $JOB_A  -> $ROOT_DIR/JobA/"
echo "JobB: $JOB_B  -> $ROOT_DIR/JobB/"

cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
job_a=$JOB_A
job_b=$JOB_B
n_train=$N_TRAIN
n_epochs=$N_EPOCHS
walltime=$WALLTIME
qos=$QOS
cluster_registry_dir=$REGISTRY_DIR
hypothesis=JobB.cold_epoch_wall close to phase1.warm_epoch_wall (~73s) via peer_lookup
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
