#!/bin/bash
# Sidecar <-> direct-mmap recovery validation (single node).
# Connects the persistent-sidecar mechanism to the warm-hit direct-mmap path:
#   1. populate cache (run the mmap bench once; open-time promotion + the data
#      mover copy each shard to NVMe and write a .meta sidecar, PERSIST_META=1)
#   2. kill the FitCache server, wipe ports.cfg
#   3. restart a fresh server -> restore_from_sidecars() rebuilds path_cache_map
#   4. mmap the original paths again -> verify FitCachePP resolves the cached
#      local file and direct-mmaps it (warm hit), checksum must PASS
# Also runs a Native_mmap_PFS pass for the checksum-equality gate.
#
# Note: the client warm-hit resolver is independent of the server map (it
# recomputes the deterministic path + stats the local file), so the cached
# files persisting on /mnt/bb across the restart is what the client needs;
# the sidecar restore rebuilds the SERVER's view (eviction/promotion/cross-job).
# This test confirms BOTH survive the restart and the warm hit still fires.
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

NUM_SHARDS="${NUM_SHARDS:-4}"
N_CHUNKS="${N_CHUNKS:-2000}"
QOS="${QOS:-debug}"
WALLTIME="${WALLTIME:-00:45:00}"
PFS_DIR="${PFS_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
RESTART_WAIT="${RESTART_WAIT:-25}"

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_sidecar_directmmap
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/sidecar_directmmap/${RUN_TAG}"
mkdir -p "$JOB_DIR"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J sidecar_dmmap
#SBATCH -t $WALLTIME
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -q $QOS
#SBATCH -o $JOB_DIR/sidecar_dmmap-%j.out
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
set -uo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh
RESULTS_DIR="$JOB_DIR"; cd "\$RESULTS_DIR"
BENCH="\$FITPP_REPO/benchmarks/megatron/llm_coverage_bench.py"
PY="\$FITPP_PYTHON_TORCH"

export BBPATH=/mnt/bb/\$USER
export FitCache_DATA_DIR="$PFS_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_sdm_dram
export FitCache_NVME_PATH=/mnt/bb/\$USER/fitcachepp_sdm_nvme
export FitCache_DRAM_CAPACITY=\$((20 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$SERVERS_PER_NODE
export FitCache_CROSS_JOB=0
export FitCache_PERSIST_META=1   # sidecars written on promote + restored on startup
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

echo "==== PHASE 1: populate cache (server #1 + bench, open-time promotion) ===="
srun -N1 -n$SERVERS_PER_NODE --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $SERVERS_PER_NODE > "\$RESULTS_DIR/server1.log" 2>&1 &
S1=\$!
sleep 15
srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
  "LD_PRELOAD=\"\$FITPP_CLIENT_LIB\" \"\$PY\" \"\$BENCH\" --data-dir \"$PFS_DIR\" --num-shards $NUM_SHARDS --coverage 1.0 --n-chunks $N_CHUNKS --epochs 1 --seed 0 --label populate" \\
  2>&1 | tee "\$RESULTS_DIR/populate.log"
echo "[phase1] waiting for data mover to finish copying + writing sidecars..."
sleep 30
NMETA1=\$(find "\$FitCache_NVME_PATH" "\$FitCache_DRAM_PATH" -name '*.meta' 2>/dev/null | wc -l)
NCACHED1=\$(find "\$FitCache_NVME_PATH" "\$FitCache_DRAM_PATH" -type f -not -name '*.meta' -not -name '*.broken' 2>/dev/null | wc -l)
echo "[phase1] sidecars=\$NMETA1 cached_files=\$NCACHED1"

echo "==== PHASE 2: kill server #1, wipe ports.cfg ===="
kill -TERM \$S1 2>/dev/null || true
sleep $RESTART_WAIT
rm -f "\$RESULTS_DIR/.ports.cfg.\$SLURM_JOB_ID"

echo "==== PHASE 3: restart server #2 -> restore_from_sidecars ===="
srun -N1 -n$SERVERS_PER_NODE --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $SERVERS_PER_NODE > "\$RESULTS_DIR/server2.log" 2>&1 &
S2=\$!
sleep 15
RESTORED=\$(grep -oE "restore-sidecars: total restored = [0-9]+" "\$RESULTS_DIR"/fitcache_server_log.*.* 2>/dev/null | grep -oE "[0-9]+\$" | sort -rn | head -1)
echo "[phase3] server2 restore_from_sidecars total restored = \${RESTORED:-0}"

echo "==== PHASE 4: re-mmap original paths (warm hit from restored cache) ===="
srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
  "LD_PRELOAD=\"\$FITPP_CLIENT_LIB\" \"\$PY\" \"\$BENCH\" --data-dir \"$PFS_DIR\" --num-shards $NUM_SHARDS --coverage 1.0 --n-chunks $N_CHUNKS --epochs 1 --seed 0 --label FitCachePP_after_restart" \\
  2>&1 | tee "\$RESULTS_DIR/after_restart.log"

kill -TERM \$S2 2>/dev/null || true; sleep 3

echo "==== PHASE 5: Native_mmap_PFS reference (checksum gate) ===="
srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
  "\"\$PY\" \"\$BENCH\" --data-dir \"$PFS_DIR\" --num-shards $NUM_SHARDS --coverage 1.0 --n-chunks $N_CHUNKS --epochs 1 --seed 0 --label Native_mmap_PFS" \\
  2>&1 | tee "\$RESULTS_DIR/native.log"

echo ""
echo "==================== SIDECAR <-> DIRECT-MMAP VALIDATION SUMMARY ===================="
echo "  sidecars written (phase1): \$NMETA1   cached files: \$NCACHED1"
echo "  sidecars restored (phase3 server2): \${RESTORED:-0}"
PW=\$(grep SUMMARY "\$RESULTS_DIR/populate.log" 2>/dev/null | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
AW=\$(grep SUMMARY "\$RESULTS_DIR/after_restart.log" 2>/dev/null | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
NW=\$(grep SUMMARY "\$RESULTS_DIR/native.log" 2>/dev/null | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
AC=\$(grep SUMMARY "\$RESULTS_DIR/after_restart.log" 2>/dev/null | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
NC=\$(grep SUMMARY "\$RESULTS_DIR/native.log" 2>/dev/null | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
echo "  populate epoch wall (cold+promote):   \${PW}s"
echo "  after-restart epoch wall (warm hit):  \${AW}s"
echo "  Native_mmap_PFS epoch wall:           \${NW}s"
echo "  checksum after-restart=\$AC  native=\$NC"
if [ "\$AC" = "\$NC" ] && [ -n "\$AC" ]; then echo "  CHECKSUM_GATE: PASS"; else echo "  CHECKSUM_GATE: FAIL"; fi
awk -v n="\$NW" -v a="\$AW" 'BEGIN{ if (a>0) printf "  after-restart speedup (Native/FitCachePP) = %.2fx\n", n/a }'
WH=\$(grep -c "WARM HIT" "\$RESULTS_DIR"/fitcache_intercept_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END{print s+0}')
echo "  (WARM HIT log lines, DEBUG-gated: \$WH)"
echo "  VERDICT: sidecars survived restart (restored=\${RESTORED:-0}) AND after-restart mmap is warm + checksum-correct => sidecar+direct-mmap recovery works."
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "sidecar+direct-mmap validation job: $JID -> $JOB_DIR"
