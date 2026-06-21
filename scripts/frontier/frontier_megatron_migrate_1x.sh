#!/bin/bash
# Megatron (dense-sequential) 2-node peer->local MIGRATION experiment (TPDS).
#
# Same shape as the DINOv2 migration run, on 16 GiB Megatron shards so the
# migration exercises the CHUNKED bulk transfer (16 GiB = 16 x 1 GiB chunks),
# which the 540 MB DINOv2 shards (single chunk) did not.
#   P1 populate: each node prefetch-promotes its OWN 1/N partition (+broadcast).
#   P2 migrate-read: each node reads the ROTATED partition -> prefetch migrates
#      the non-owned shards peer->local, then reads them warm.
# Partition is the opt-in 1/N slice: FITCACHE_PART_WORLD=N_NODES, rank defaults
# to SLURM_PROCID; rotate=1 in P2 makes a node read the peer's slice.
#
# Usage: N_NODES=2 TOTAL_SHARDS=2 QOS=debug bash scripts/frontier/frontier_megatron_migrate_1x.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-2}"
TOTAL_SHARDS="${TOTAL_SHARDS:-2}"   # total shards across all nodes (world slices it: per-node = TOTAL/N)
EPOCHS="${EPOCHS:-2}"
N_CHUNKS="${N_CHUNKS:-4000}"
QOS="${QOS:-debug}"
PARTITION="${PARTITION:-$FITPP_SLURM_PARTITION}"
WALLTIME="${WALLTIME:-00:45:00}"
DATA_DIR="${DATA_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb}"
TOTAL_SERVERS=$N_NODES

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_megatron_migrate_N${N_NODES}
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/megatron_migrate_1x/${RUN_TAG}"
mkdir -p "$JOB_DIR"
QOS_LINE=""; [ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J mega_mig_N${N_NODES}
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/mega_mig-%j.out
set -uo pipefail
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
cd "\$FITPP_REPO"
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh
RESULTS_DIR="$JOB_DIR"; cd "\$RESULTS_DIR"
BENCH="\$FITPP_REPO/benchmarks/megatron/llm_coverage_bench.py"
PY="\$FITPP_PYTHON_TORCH"
LIB="\$FITPP_CLIENT_LIB"

export BBPATH=/mnt/bb/\$USER
export FitCache_DATA_DIR="$DATA_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_mmig_dram
export FitCache_NVME_PATH=/mnt/bb/\$USER/fitcachepp_mmig_nvme
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

echo "=== PHASE 1: prefetch-populate own 1/N partition (rotate=0, promote + broadcast) ==="
srun --overlap -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_WORLD=$N_NODES FITCACHE_PART_ROTATE=0 FITCACHE_PREFETCH=1 FITCACHE_PREFETCH_WAIT_SEC=300 LD_PRELOAD=\\"\$LIB\\" \\"\$PY\\" \\"\$BENCH\\" --data-dir \\"$DATA_DIR\\" --num-shards $TOTAL_SHARDS --coverage 1.0 --n-chunks $N_CHUNKS --epochs 1 --seed 0 --label populate_own" \\
  2>&1 | tee "\$RESULTS_DIR/phase1.log"
sleep 5
echo "--- aggregate cache after Phase 1 (per node = its 1x partition) ---"
srun --overlap -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpu-bind=cores \\
  bash -c 'echo "[after-populate] node=\$SLURM_NODEID host=\$(hostname) cache_bytes=\$(du -sb "\$FitCache_NVME_PATH" 2>/dev/null | cut -f1)"' 2>&1 | sort

echo "=== PHASE 2: migrate-read rotated partition (rotate=1, prefetch -> CHUNKED migrate) ==="
srun --overlap -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_WORLD=$N_NODES FITCACHE_PART_ROTATE=1 FITCACHE_PREFETCH=1 FITCACHE_PREFETCH_WAIT_SEC=300 LD_PRELOAD=\\"\$LIB\\" \\"\$PY\\" \\"\$BENCH\\" --data-dir \\"$DATA_DIR\\" --num-shards $TOTAL_SHARDS --coverage 1.0 --n-chunks $N_CHUNKS --epochs $EPOCHS --seed 0 --label migrate_read" \\
  2>&1 | tee "\$RESULTS_DIR/phase2.log"
sleep 3
echo "--- aggregate cache after Phase 2 (now also holds the migrated partition) ---"
srun --overlap -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpu-bind=cores \\
  bash -c 'echo "[after-migrate] node=\$SLURM_NODEID host=\$(hostname) cache_bytes=\$(du -sb "\$FitCache_NVME_PATH" 2>/dev/null | cut -f1)"' 2>&1 | sort

kill -TERM \$SPID 2>/dev/null || true; sleep 2

echo
echo "==================== MEGATRON MIGRATION SUMMARY (N=$N_NODES, $TOTAL_SHARDS total shards) ===================="
echo "--- Phase 2 prefetch hint + warm-hit (per rank) ---"
grep -aE "prefetch: hinted|cov-bench.*SUMMARY" "\$RESULTS_DIR/phase2.log" 2>/dev/null
echo "--- migration trace (server logs; 16 GiB shard -> ~16 chunks each) ---"
grep -ahE "Data mover: migrated .* from peer" "\$RESULTS_DIR"/fitcache_server_log.* 2>/dev/null | tail -10
MIG=\$(grep -acE "Data mover: migrated .* from peer" "\$RESULTS_DIR"/fitcache_server_log.* 2>/dev/null | awk -F: '{s+=\$NF} END{print s+0}')
echo "--- migrations observed: \$MIG (expect ~$TOTAL_SHARDS = each node migrates the peer's $((TOTAL_SHARDS/N_NODES)) shard(s)) ---"
echo "result path: \$RESULTS_DIR"
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "megatron migration experiment N=$N_NODES job: $JID -> $JOB_DIR"
echo "log: $JOB_DIR/mega_mig-${JID}.out"
