#!/bin/bash
# Frontier sidecar warm-restart validation experiment.
#
# Validates the persistent-metadata-sidecar contribution: after a
# FitCache server process is killed mid-training, a fresh server process
# started against the SAME on-disk tier directories must rebuild
# path_cache_map from the .meta sidecars and serve the next training
# epoch from cache rather than re-fetching from PFS.
#
# Sequence (single sbatch job, 1 node, 8 GPU):
#   1. Spawn server srun #1 (4 servers).
#   2. Training invocation A: 1 cosmoflow epoch at n=32768.
#      -> populates FitCache_NVME_PATH with cached files + .meta sidecars.
#      -> expected wall ~365s (cold).
#   3. Kill server srun #1 PID. Wait 30s.
#   4. Wipe .ports.cfg.$SLURM_JOBID (servers append, not truncate, so we
#      must remove stale rank entries before srun #2 writes fresh ones).
#   5. Spawn server srun #2 (same FitCache_DRAM_PATH/NVME_PATH).
#      -> startup calls fitcache_data_mover_restore_from_sidecars()
#         under FitCache_CROSS_JOB=1 (required gate).
#   6. Training invocation B: 1 cosmoflow epoch at n=32768.
#      -> expected wall ~285s if sidecar restore worked (matches Epoch 2
#         warm wall from the headline run), ~365s if sidecar restore did
#         not pick up the cached files.
#
# Compare invocation B wall against:
#   - cold baseline: ~365s (headline Epoch 1 at n=32768/1N).
#   - warm baseline: ~285s (headline Epoch 2 at n=32768/1N).
#
# Usage:
#   bash scripts/frontier/frontier_cosmoflow_sidecar_warmrestart.sh
#
# Env overrides:
#   FITPP_N_TRAIN          default 32768
#   N_NODES                default 1
#   SERVERS_PER_NODE       default 4
#   GPUS_PER_NODE          default 8
#   WALLTIME               default 02:00:00
#   QOS                    default hackathon
#   SERVER_RESTART_WAIT    default 30  (seconds between srun #1 kill and srun #2)

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-1}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
GPUS_PER_NODE="${GPUS_PER_NODE:-8}"
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))
N_TRAIN="${FITPP_N_TRAIN:-32768}"
N_VALID="${FITPP_N_VALID:-1024}"
WALLTIME="${WALLTIME:-02:00:00}"
QOS="${QOS:-hackathon}"
SERVER_RESTART_WAIT="${SERVER_RESTART_WAIT:-30}"

COSMOFLOW_DATA="${COSMOFLOW_DATA:-${FITPP_PFS_DATA_ROOT}/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2}"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_sidecar_warmrestart
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/sidecar_warmrestart/${RUN_TAG}"
mkdir -p "$ROOT_DIR"

QOS_LINE=""
[ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

JOB_DIR="$ROOT_DIR"
TOTAL_GPUS=$((N_NODES * GPUS_PER_NODE))

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J sidecar_warmrestart
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/sidecar_warmrestart-%j.out

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
# IDENTICAL DRAM/NVME paths across the two server lifetimes — this is
# what makes the warm-restart claim meaningful.
export FitCache_DRAM_PATH=/tmp/fitcachepp_sidecar_${RUN_TAG}_dram
export FitCache_NVME_PATH=/tmp/fitcachepp_sidecar_${RUN_TAG}_nvme
export FitCache_DRAM_CAPACITY=\$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$TOTAL_SERVERS
# Sidecar mechanism is now decoupled from cross-job. Single-job mode +
# persist-meta = exactly what we want to validate: the sidecar write
# during Phase 1 + the restore-from-sidecars during server srun #2's
# startup. Cross-job machinery (registry threads, heartbeat,
# sibling-refresh, peer-lookup) stays OFF so it can't skew Horovod
# ranks (the 2026-05-18T23 timeout root cause).
export FitCache_CROSS_JOB=0
export FitCache_PERSIST_META=1
export FITPP_SKIP_MANIFEST_SCAN=1
export FITPP_TIMING_DUMP_ON_EXIT=1
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

# MIOpen / TF / Horovod knobs (same as headline cosmoflow)
export MIOPEN_DISABLE_CACHE=1
export MIOPEN_FIND_MODE=3
export MIOPEN_USER_DB_PATH=/tmp/miopen_cache_\$SLURM_PROCID
mkdir -p \$MIOPEN_USER_DB_PATH
export TF_ROCM_FUSION_DISABLE=1
export TF_XLA_FLAGS="--tf_xla_auto_jit=0 --tf_xla_cpu_global_jit=false"
export TF_CPP_MIN_LOG_LEVEL=3
export HOROVOD_STALL_CHECK_TIME_SECONDS=600
export HOROVOD_STALL_SHUTDOWN_TIME_SECONDS=0
export HOROVOD_CYCLE_TIME=5

echo "[sidecar-warmrestart] nodes=$N_NODES  total_servers=$TOTAL_SERVERS  gpus=$TOTAL_GPUS"
echo "[sidecar-warmrestart] DRAM=\$FitCache_DRAM_PATH"
echo "[sidecar-warmrestart] NVME=\$FitCache_NVME_PATH"
echo "[sidecar-warmrestart] data=\$FitCache_DATA_DIR"
echo "[sidecar-warmrestart] n_train=$N_TRAIN n_valid=$N_VALID"
echo "[sidecar-warmrestart] cross_job=\$FitCache_CROSS_JOB  persist_meta=\$FitCache_PERSIST_META"

# Training wrapper — re-used by both invocations. n_epochs=1 in each.
WRAPPER="\$RESULTS_DIR/train_wrapper.sh"
cat > "\$WRAPPER" <<'WEOF'
#!/bin/bash
cd \$FITPP_COSMOFLOW_DIR
LD_PRELOAD="\$FITPP_CLIENT_LIB" \$FITPP_PYTHON_TF \\
    \$FITPP_COSMOFLOW_DIR/train.py -d \\
    --data-dir "\$FitCache_DATA_DIR" \\
    --n-train $N_TRAIN \\
    --n-valid $N_VALID \\
    --n-epochs 1
WEOF
chmod +x "\$WRAPPER"

# ============================================================
# Phase 1: cold epoch — populates cache + writes .meta sidecars
# ============================================================
echo ""
echo "===================================================================="
echo "[sidecar-warmrestart] PHASE 1: server srun #1 + cold training epoch"
echo "===================================================================="

srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE \\
     --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS \\
     > "\$RESULTS_DIR/server1_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER1_PID=\$!
echo "[sidecar-warmrestart] server srun #1 PID=\$SERVER1_PID"
sleep 15

echo "[sidecar-warmrestart] starting training invocation A (cold)"
START_A=\$SECONDS
srun -N $N_NODES -c4 --gpus-per-node=$GPUS_PER_NODE --ntasks-per-gpu=1 \\
     --cpu-bind=cores "\$WRAPPER" \\
     2>&1 | tee "\$RESULTS_DIR/train_A_cold_\${SLURM_JOB_ID}.log"
TRAIN_A_RC=\${PIPESTATUS[0]}
END_A=\$SECONDS
WALL_A=\$((END_A - START_A))
echo "[sidecar-warmrestart] training A wall=\${WALL_A}s rc=\$TRAIN_A_RC"

# ============================================================
# Server kill + sidecar inventory + ports.cfg wipe
# ============================================================
echo ""
echo "===================================================================="
echo "[sidecar-warmrestart] PHASE 2: kill server #1, inventory sidecars, restart"
echo "===================================================================="

echo "[sidecar-warmrestart] killing server srun #1 (PID \$SERVER1_PID)"
kill -TERM \$SERVER1_PID 2>/dev/null || true
sleep $SERVER_RESTART_WAIT

# Inventory: how many sidecars did Phase 1 leave on disk?
N_META_NVME=\$(find "\$FitCache_NVME_PATH" -name '*.meta' 2>/dev/null | wc -l)
N_META_DRAM=\$(find "\$FitCache_DRAM_PATH" -name '*.meta' 2>/dev/null | wc -l)
N_CACHED_NVME=\$(find "\$FitCache_NVME_PATH" -type f -not -name '*.meta' -not -name '*.broken' 2>/dev/null | wc -l)
N_CACHED_DRAM=\$(find "\$FitCache_DRAM_PATH" -type f -not -name '*.meta' -not -name '*.broken' 2>/dev/null | wc -l)
echo "[sidecar-warmrestart] post-kill sidecar inventory:"
echo "  NVME tier: \$N_META_NVME .meta files, \$N_CACHED_NVME cached files"
echo "  DRAM tier: \$N_META_DRAM .meta files, \$N_CACHED_DRAM cached files"

# Wipe stale .ports.cfg so server srun #2's fresh entries are the ONLY
# ones the client sees in invocation B.
PORTS_CFG="\$RESULTS_DIR/.ports.cfg.\$SLURM_JOB_ID"
if [ -f "\$PORTS_CFG" ]; then
    echo "[sidecar-warmrestart] wiping stale ports.cfg: \$PORTS_CFG"
    rm -f "\$PORTS_CFG"
fi

# No cluster registry to clear in single-job-persist-meta mode
# (FitCache_CROSS_JOB=0). The registry is only populated when
# cross-job mode is on.

# ============================================================
# Phase 3: server srun #2 — should run restore_from_sidecars
# ============================================================
echo ""
echo "===================================================================="
echo "[sidecar-warmrestart] PHASE 3: server srun #2 + warm-after-restart epoch"
echo "===================================================================="

srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE \\
     --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS \\
     > "\$RESULTS_DIR/server2_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER2_PID=\$!
echo "[sidecar-warmrestart] server srun #2 PID=\$SERVER2_PID"
sleep 15

echo "[sidecar-warmrestart] starting training invocation B (warm-after-restart)"
START_B=\$SECONDS
srun -N $N_NODES -c4 --gpus-per-node=$GPUS_PER_NODE --ntasks-per-gpu=1 \\
     --cpu-bind=cores "\$WRAPPER" \\
     2>&1 | tee "\$RESULTS_DIR/train_B_warmrestart_\${SLURM_JOB_ID}.log"
TRAIN_B_RC=\${PIPESTATUS[0]}
END_B=\$SECONDS
WALL_B=\$((END_B - START_B))
echo "[sidecar-warmrestart] training B wall=\${WALL_B}s rc=\$TRAIN_B_RC"

# ============================================================
# Teardown + summary
# ============================================================
echo ""
echo "===================================================================="
echo "[sidecar-warmrestart] PHASE 4: teardown + summary"
echo "===================================================================="
kill -TERM \$SERVER2_PID 2>/dev/null || true
sleep 5

# Pull restore_from_sidecars evidence from server #2 logs.
RESTORE_LINES=\$(grep -E "restore-sidecars: total restored|restore-sidecars: restored" \\
                  "\$RESULTS_DIR"/server2_\${SLURM_JOB_ID}.log 2>/dev/null || true)
RESTORED_TOTAL=\$(echo "\$RESTORE_LINES" | grep -oE "total restored = [0-9]+" | grep -oE "[0-9]+" | head -1)
RESTORED_TOTAL=\${RESTORED_TOTAL:-0}

# Open RPC counts: how many opens did each invocation issue?
OPEN_A=\$(grep -cE "Open RPC: requested path" "\$RESULTS_DIR"/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
# (Both invocations share the same intercept log because the file name
# includes only PID + rank — separate srun = separate intercept logs;
# total is fine to report as a single number.)

echo "----- sidecar-warmrestart summary -----"
echo "  Phase 1 (cold) wall:            \${WALL_A}s   rc=\$TRAIN_A_RC"
echo "  Phase 3 (warm-restart) wall:    \${WALL_B}s   rc=\$TRAIN_B_RC"
echo "  Sidecars on disk after Phase 1: NVME=\$N_META_NVME  DRAM=\$N_META_DRAM"
echo "  Cached files after Phase 1:     NVME=\$N_CACHED_NVME  DRAM=\$N_CACHED_DRAM"
echo "  restore_from_sidecars output (server #2 startup):"
echo "\$RESTORE_LINES" | sed 's/^/    /'
echo "  Total restored at server #2 startup: \$RESTORED_TOTAL"
echo ""
echo "Headline references at n=32768/1N (for comparison):"
echo "  cold epoch baseline ~ 365s"
echo "  warm epoch baseline ~ 285s"
echo ""
echo "If sidecar warm-restart works, Phase 3 wall should land near 285s."
echo "If it doesn't, Phase 3 wall will look like Phase 1 (~365s)."
EOF

chmod +x "$JOB_DIR/job.sh"

JOB_ID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "sidecar-warmrestart job: $JOB_ID -> $ROOT_DIR/"

cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
job_id=$JOB_ID
qos=$QOS
walltime=$WALLTIME
n_nodes=$N_NODES
gpus_per_node=$GPUS_PER_NODE
servers_per_node=$SERVERS_PER_NODE
total_servers=$TOTAL_SERVERS
n_train=$N_TRAIN
n_valid=$N_VALID
data_dir=$COSMOFLOW_DATA
server_restart_wait_sec=$SERVER_RESTART_WAIT
hypothesis=phase3.wall ~ warm_baseline (~285s) if sidecar restore works; else cold (~365s)
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
