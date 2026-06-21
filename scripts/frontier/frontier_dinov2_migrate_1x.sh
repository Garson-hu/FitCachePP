#!/bin/bash
# DINOv2 / CC12M 2-node peer->local MIGRATION experiment (TPDS).
#
# Shows 1x storage (each node caches only its own 1/N partition) and that
# prefetch-informed migration brings a NON-owned partition to a node just in
# time, preserving the warm-hit. Phases:
#   P1 populate (organic): each node's LD_PRELOAD client reads its OWN disjoint
#      partition -> node-local server promotes + BROADCASTS presence. Aggregate
#      cache = full corpus once (1x), not N x.
#   P2 migrate-read: each node reads the ROTATED (peer's) partition with
#      FITCACHE_PREFETCH=1 + FITCACHE_PART_ROTATE=1 -> prefetch migrates the
#      non-owned shards peer->local, then the epoch reads them warm.
# Routing = node_local (each client -> own node's server); cross-job on for the
# presence broadcast that lets a peer discover the migration source.
#
# Usage: N_NODES=2 NUM_SHARDS=4 QOS=debug bash scripts/frontier/frontier_dinov2_migrate_1x.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-2}"
NUM_SHARDS="${NUM_SHARDS:-4}"
EPOCHS="${EPOCHS:-2}"
QOS="${QOS:-debug}"
PARTITION="${PARTITION:-$FITPP_SLURM_PARTITION}"
WALLTIME="${WALLTIME:-00:30:00}"
DATA_DIR="${DATA_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/dinov2/cc12m_wds}"
TOTAL_SERVERS=$N_NODES   # 1 server/node

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_dinov2_migrate_N${N_NODES}
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/dinov2_migrate_1x/${RUN_TAG}"
mkdir -p "$JOB_DIR"
QOS_LINE=""; [ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J dino_mig_N${N_NODES}
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/dino_mig-%j.out
set -uo pipefail
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
cd "\$FITPP_REPO"
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh
RESULTS_DIR="$JOB_DIR"; cd "\$RESULTS_DIR"
BENCH="\$FITPP_REPO/benchmarks/dinov2/cc12m_mmap_bench.py"
PY="\$FITPP_PYTHON_TORCH"
LIB="\$FITPP_CLIENT_LIB"

export BBPATH=/mnt/bb/\$USER
export FitCache_DATA_DIR="$DATA_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_dmig_dram
export FitCache_NVME_PATH=/mnt/bb/\$USER/fitcachepp_dmig_nvme
export FitCache_DRAM_CAPACITY=\$((256 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((2000 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=700
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$TOTAL_SERVERS
export FitCache_CROSS_JOB=1
export FitCache_PREFER_MIGRATE=1
export FITCACHE_MMAP_PLACEMENT=node_local
export FitCache_CLUSTER_REGISTRY_DIR="\$RESULTS_DIR/registry"
export FitCache_HEARTBEAT_SEC=3
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH" "\$FitCache_CLUSTER_REGISTRY_DIR"

echo "=== start $TOTAL_SERVERS server(s), 1/node ==="
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=1 --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS > "\$RESULTS_DIR/server.log" 2>&1 &
SPID=\$!
ND="\$RESULTS_DIR/registry/registry.v1/nodes"
for i in \$(seq 1 30); do
  n=0; [ -d "\$ND" ] && n=\$(grep -h '^server\..*\.addr=' "\$ND"/*.txt 2>/dev/null | wc -l)
  [ "\$n" -ge $TOTAL_SERVERS ] && { echo "registry: \$n live after \${i}s"; break; }
  sleep 1
done

echo "=== PHASE 1: populate own partition (rotate=0, prefetch -> promote + broadcast) ==="
# Use prefetch to promote each node's OWN partition from PFS into its local tier
# and broadcast presence (a plain mmap read does not trigger a promote). No peer
# has these shards yet, so the data mover PFS-promotes + broadcasts. This is the
# 1x staging: each node ends up holding only its own 1/N.
srun --overlap -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_ROTATE=0 FITCACHE_PREFETCH=1 FITCACHE_PREFETCH_WAIT_SEC=120 LD_PRELOAD=\\"\$LIB\\" \\"\$PY\\" \\"\$BENCH\\" --data-dir \\"$DATA_DIR\\" --num-shards $NUM_SHARDS --epochs 1 --decode-every 50 --label populate_own" \\
  2>&1 | tee "\$RESULTS_DIR/phase1.log"
sleep 5
echo "--- aggregate cache after Phase 1 (per node = its 1x partition) ---"
srun --overlap -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpu-bind=cores \\
  bash -c 'echo "[after-populate] node=\$SLURM_NODEID host=\$(hostname) cache_bytes=\$(du -sb "\$FitCache_NVME_PATH" 2>/dev/null | cut -f1)"' 2>&1 | sort

echo "=== PHASE 2: migrate-read rotated partition (rotate=1, prefetch -> migrate) ==="
srun --overlap -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_ROTATE=1 FITCACHE_PREFETCH=1 FITCACHE_PREFETCH_WAIT_SEC=120 LD_PRELOAD=\\"\$LIB\\" \\"\$PY\\" \\"\$BENCH\\" --data-dir \\"$DATA_DIR\\" --num-shards $NUM_SHARDS --epochs $EPOCHS --decode-every 50 --label migrate_read" \\
  2>&1 | tee "\$RESULTS_DIR/phase2.log"
sleep 3
echo "--- aggregate cache after Phase 2 (now also holds the migrated partition) ---"
srun --overlap -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpu-bind=cores \\
  bash -c 'echo "[after-migrate] node=\$SLURM_NODEID host=\$(hostname) cache_bytes=\$(du -sb "\$FitCache_NVME_PATH" 2>/dev/null | cut -f1)"' 2>&1 | sort

kill -TERM \$SPID 2>/dev/null || true; sleep 2

echo
echo "==================== DINOV2 MIGRATION SUMMARY (N=$N_NODES, $NUM_SHARDS shards/node) ===================="
echo "--- Phase 2 prefetch hint + warm-hit (per rank) ---"
grep -aE "prefetch: hinted|CC12M-SUMMARY" "\$RESULTS_DIR/phase2.log" 2>/dev/null
echo "--- migration trace (server logs) ---"
grep -ahE "Data mover: migrated .* from peer" "\$RESULTS_DIR"/fitcache_server_log.* 2>/dev/null | tail -20
MIG=\$(grep -acE "Data mover: migrated .* from peer" "\$RESULTS_DIR"/fitcache_server_log.* 2>/dev/null | awk -F: '{s+=\$NF} END{print s+0}')
echo "--- migrations observed: \$MIG (expect ~$((N_NODES * NUM_SHARDS)) = each node migrates the peer's $NUM_SHARDS shards) ---"
echo "result path: \$RESULTS_DIR"
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "dinov2 migration experiment N=$N_NODES job: $JID -> $JOB_DIR"
echo "log: $JOB_DIR/dino_mig-${JID}.out"
