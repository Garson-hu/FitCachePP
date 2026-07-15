#!/bin/bash
# Megatron WEAK-SCALING launcher: per-node data held constant at 32 shards x
# 4 GiB = 128 GiB/node; total corpus grows with N (still 1x: the cluster holds
# that scale's dataset once). Each scale reads a DISJOINT shard range of
# synth_weak_16320x4gb via FITCACHE_SHARD_BASE, so every native is cold.
# Real-case loader layout: 8 DataLoader ranks/node x num_workers=4.
# usage: run_megatron_weak.sh <N_nodes> <shard_base>
set -euo pipefail
N=$1
BASE=$2
REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP
SPN=32                       # shards/node, constant (128 GiB/node)
NS=$(( SPN * N ))            # this scale's shard count (window size)
SPS=3125                     # 32 shards x 3125 = 100k samples/node, constant
TARGET=$(( SPN * 4 * 1024 * 1024 * 1024 * 95 / 100 ))
TS=$(date +%Y%m%d_%H%M%S)
RD=$REPO/benchmarks/results/frontier/megatron_weak_1x/${TS}_N${N}
mkdir -p "$RD"
QOSLINE=""; [ "${FITPP_DEBUG:-0}" = "1" ] && QOSLINE="#SBATCH -q debug"
BEGINLINE=""; [ -n "${FITPP_BEGIN:-}" ] && BEGINLINE="#SBATCH --begin=${FITPP_BEGIN}"
case $N in 128|256) WT=01:30:00;; 32|64) WT=01:00:00;; *) WT=00:45:00;; esac
cat > "$RD/job.sh" <<EOF
#!/bin/bash
#SBATCH -J mweak_N${N}
#SBATCH -t ${WT}
#SBATCH -N ${N}
#SBATCH -C nvme
#SBATCH -p batch
${QOSLINE}
${BEGINLINE}
#SBATCH --account=gen008
#SBATCH -o ${RD}/mweak-%j.out
set -uo pipefail
export FITPP_SITE=frontier FITPP_REPO=${REPO}
cd "\$FITPP_REPO"; source benchmarks/sites/_resolve.sh
RD="${RD}"; cd "\$RD"
RB="\$FITPP_REPO/benchmarks/megatron/megatron_dataloader_bench.py"
CB="\$FITPP_REPO/benchmarks/megatron/llm_coverage_bench.py"
PY="\$FITPP_PYTHON_TORCH"; LIB="\$FITPP_CLIENT_LIB"
DATA="/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_weak_16320x4gb"
export BBPATH=/mnt/bb/\$USER FitCache_DATA_DIR="\$DATA"
export FitCache_DRAM_PATH=/tmp/fcpp_mweak_dram FitCache_NVME_PATH=/mnt/bb/\$USER/fcpp_mweak_nvme
export FitCache_DRAM_CAPACITY=\$((256*1024*1024)) FitCache_NVME_CAPACITY=\$((1700*1024*1024*1024))
export FitCache_LOG_LEVEL=700 FitCache_PORTS_CFG_DIR="\$RD" FitCache_SERVER_COUNT=${N}
export FitCache_CROSS_JOB=0 FitCache_PREFER_MIGRATE=1 FITCACHE_MMAP_PLACEMENT=node_local
export FitCache_CLUSTER_REGISTRY_DIR="\$RD/registry" FitCache_HEARTBEAT_SEC=120
export FITCACHE_SHARD_BASE=${BASE}
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH" "\$FitCache_CLUSTER_REGISTRY_DIR"
echo "WEAK N=${N} shards/node=${SPN} (128GiB/node) window=${NS} base=${BASE} samples/shard=${SPS}"

echo "=== STEP 1: NATIVE random (cold Lustre), 8 ranks/node x 4 workers ==="
srun -N ${N} -n \$((8*${N})) --ntasks-per-node=8 --cpus-per-task=7 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_WORLD=${N} FITCACHE_PART_ROTATE=0 FITCACHE_SHARD_BASE=${BASE} \"\$PY\" \"\$RB\" --data-dir \"\$DATA\" --num-shards ${NS} --samples-per-shard ${SPS} --seq-length 1024 --workers 4 --batch-size 16 --label _native" \\
  2>&1 | tee "\$RD/native.log"

echo "=== start ${N} server(s) 1/node ==="
srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 --cpus-per-task=1 --cpu-bind=cores "\$FITPP_SERVER_BIN" ${N} > "\$RD/server.log" 2>&1 &
SPID=\$!
ND="\$RD/registry/registry.v1/nodes"
for i in \$(seq 1 30); do n=0; [ -d "\$ND" ] && n=\$(grep -h '^server\\..*\\.addr=' "\$ND"/*.txt 2>/dev/null|wc -l); [ "\$n" -ge ${N} ] && break; sleep 1; done

echo "=== STEP 2: POPULATE (prefetch whole shards to NVMe) ==="
srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_WORLD=${N} FITCACHE_PART_ROTATE=0 FITCACHE_SHARD_BASE=${BASE} FITCACHE_PREFETCH=1 LD_PRELOAD=\"\$LIB\" \"\$PY\" \"\$CB\" --data-dir \"\$DATA\" --num-shards ${NS} --coverage 1.0 --n-chunks 4000 --epochs 1 --seed 0 --label populate" \\
  2>&1 | tee "\$RD/populate.log"

echo "=== wait for cache (target ${TARGET}B/node) ==="
for i in \$(seq 1 60); do
  minb=\$(srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 bash -c 'du -sb "\$FitCache_NVME_PATH" 2>/dev/null|cut -f1' 2>/dev/null | sort -n | head -1); minb=\${minb:-0}
  echo "  t=\$((i*15))s min_node_cache=\$minb"
  [ "\$minb" -ge ${TARGET} ] && { echo "cached"; break; }
  sleep 15
done

echo "=== STEP 3: WARM random (NVMe), 8 ranks/node x 4 workers ==="
srun --overlap -N ${N} -n \$((8*${N})) --ntasks-per-node=8 --cpus-per-task=7 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_WORLD=${N} FITCACHE_PART_ROTATE=0 FITCACHE_SHARD_BASE=${BASE} LD_PRELOAD=\"\$LIB\" \"\$PY\" \"\$RB\" --data-dir \"\$DATA\" --num-shards ${NS} --samples-per-shard ${SPS} --seq-length 1024 --workers 4 --batch-size 16 --label _warm" \\
  2>&1 | tee "\$RD/warm.log"
kill -TERM \$SPID 2>/dev/null || true; sleep 2
echo; echo "============ MEGATRON WEAK-SCALING SUMMARY (N=${N}, 128GiB/node, base=${BASE}) ============"
echo "--- NATIVE ---"; grep -aE 'RAND:' "\$RD/native.log" | head -4
echo "--- WARM ---";   grep -aE 'RAND:' "\$RD/warm.log" | head -4
echo "--- footprint du/node ---"; timeout 300 srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 bash -c 'echo node=\$SLURM_NODEID \$(du -sh "\$FitCache_NVME_PATH" 2>/dev/null|cut -f1)' 2>&1 | sort | head -3
echo "result: \$RD"
EOF
echo "N=${N}: weak 128GiB/node base=${BASE} window=${NS}  dir=$RD"
bash -n "$RD/job.sh" && sbatch "$RD/job.sh"
