#!/bin/bash
# Multi-node Megatron warm-hit mmap sweep: FitCachePP (warm-hit direct
# local-NVMe mmap) vs Native_mmap_PFS, at N_NODES in {1,2,4,8,16}, 2 epochs.
#
# Design: each node independently runs the coverage bench over the SAME
# NUM_SHARDS shards (640 GiB > 512 GB node RAM, so Native cannot page-cache
# it). Each node PRE-STAGES its shard set to its own node-local NVMe
# (/mnt/bb/$USER) at the resolver's deterministic hash-bin path, so every
# FitCachePP mmap is a guaranteed warm hit served from local NVMe — this
# isolates the warm-hit DIRECT-MMAP mechanism from the cross-node
# server-routing question (organic multi-node promotion needs node-local
# routing, a separate follow-up). At high N the Native side also stresses
# shared Lustre (N nodes reading concurrently), so the FitCachePP advantage
# is expected to grow with N.
#
# Checksum equality (FitCachePP vs Native_mmap_PFS) is a hard gate.
#
# Usage: N_NODES=4 bash scripts/frontier/frontier_megatron_warmhit_sweep.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-1}"
NUM_SHARDS="${NUM_SHARDS:-40}"
EPOCHS="${EPOCHS:-2}"
N_CHUNKS="${N_CHUNKS:-4000}"
SEED="${SEED:-0}"
QOS="${QOS:-normal}"
WALLTIME="${WALLTIME:-01:30:00}"
PFS_DIR="${PFS_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_megatron_warmhit_N${N_NODES}
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/megatron_warmhit_sweep/${RUN_TAG}"
mkdir -p "$JOB_DIR"
QOS_LINE=""; [ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J mega_wh_N${N_NODES}
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/mega_wh-%j.out
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
set -uo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh
RESULTS_DIR="$JOB_DIR"; cd "\$RESULTS_DIR"
BENCH="\$FITPP_REPO/benchmarks/megatron/llm_coverage_bench.py"
PY="\$FITPP_PYTHON_TORCH"
TOOL="\$FITPP_REPO/tools/fitcache_cached_path"

export BBPATH=/mnt/bb/\$USER
export FitCache_DATA_DIR="$PFS_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_mwh_dram
export FitCache_NVME_PATH=/mnt/bb/\$USER/fitcachepp_mwh_nvme
export FitCache_DRAM_CAPACITY=\$((40 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((2000 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$TOTAL_SERVERS
export FitCache_CROSS_JOB=0

# --- per-node pre-stage: every node copies the NUM_SHARDS shards to its own
#     node-local NVMe at the resolver hash-bin path. Run on every node. ---
cat > "\$RESULTS_DIR/stage.sh" <<'SEOF'
#!/bin/bash
mkdir -p "\$FitCache_NVME_PATH"
for i in \$(seq 0 \$(($NUM_SHARDS - 1))); do
  src=\$(printf "$PFS_DIR/shard_%04d.bin" \$i)
  dst=\$("\$FITPP_REPO/tools/fitcache_cached_path" "\$src" "\$FitCache_NVME_PATH")
  mkdir -p "\$(dirname "\$dst")"
  if [ ! -f "\$dst" ] || [ "\$(stat -c %s "\$dst" 2>/dev/null||echo 0)" != "\$(stat -c %s "\$src")" ]; then
    cp "\$src" "\$dst"
  fi
done
echo "[stage] \$(hostname): staged $NUM_SHARDS shards, \$(du -sb "\$FitCache_NVME_PATH"|awk '{print \$1}') bytes"
SEOF
chmod +x "\$RESULTS_DIR/stage.sh"
echo "=== PRE-STAGE on all $N_NODES nodes ==="
STAGE_START=\$SECONDS
srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpu-bind=cores "\$RESULTS_DIR/stage.sh"
echo "stage wall=\$((SECONDS - STAGE_START))s"

# --- servers (one set across the allocation; warm-hit doesn't need them but
#     keeps the open RPC path realistic) ---
mkdir -p "\$FitCache_DRAM_PATH"
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS > "\$RESULTS_DIR/server.log" 2>&1 &
SPID=\$!
sleep 15

run () { # label preload logf
  echo "=== \$1 (N=$N_NODES, $NUM_SHARDS shards, $EPOCHS ep) ==="
  if [ -n "\$2" ]; then
    srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \\
      "LD_PRELOAD=\"\$2\" \"\$PY\" \"\$BENCH\" --data-dir \"$PFS_DIR\" --num-shards $NUM_SHARDS --coverage 1.0 --n-chunks $N_CHUNKS --epochs $EPOCHS --seed $SEED --label \"\$1\"" \\
      2>&1 | tee "\$RESULTS_DIR/\$3"
  else
    srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \\
      "\"\$PY\" \"\$BENCH\" --data-dir \"$PFS_DIR\" --num-shards $NUM_SHARDS --coverage 1.0 --n-chunks $N_CHUNKS --epochs $EPOCHS --seed $SEED --label \"\$1\"" \\
      2>&1 | tee "\$RESULTS_DIR/\$3"
  fi
}

run "Native_mmap_PFS"          ""                    "native.log"
run "FitCachePP_warmhit_mmap"  "\$FITPP_CLIENT_LIB"  "fitcachepp.log"

kill -TERM \$SPID 2>/dev/null || true; sleep 3

echo ""
echo "==================== MEGATRON WARM-HIT SWEEP SUMMARY (N=$N_NODES) ===================="
# rank-0 SUMMARY lines (every rank does identical work, so rank-0 is representative)
NCOLD=\$(grep "EPOCH 0" "\$RESULTS_DIR/native.log" 2>/dev/null | head -1 | grep -oE 'wall=[0-9.]+' | head -1 | cut -d= -f2)
NWARM=\$(grep "EPOCH 1" "\$RESULTS_DIR/native.log" 2>/dev/null | head -1 | grep -oE 'wall=[0-9.]+' | head -1 | cut -d= -f2)
FCOLD=\$(grep "EPOCH 0" "\$RESULTS_DIR/fitcachepp.log" 2>/dev/null | head -1 | grep -oE 'wall=[0-9.]+' | head -1 | cut -d= -f2)
FWARM=\$(grep "EPOCH 1" "\$RESULTS_DIR/fitcachepp.log" 2>/dev/null | head -1 | grep -oE 'wall=[0-9.]+' | head -1 | cut -d= -f2)
NC=\$(grep SUMMARY "\$RESULTS_DIR/native.log" 2>/dev/null | head -1 | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
FC=\$(grep SUMMARY "\$RESULTS_DIR/fitcachepp.log" 2>/dev/null | head -1 | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
echo "  N=$N_NODES shards=$NUM_SHARDS (per node) epochs=$EPOCHS"
echo "  Native_mmap_PFS         epoch0=\${NCOLD}s epoch1=\${NWARM}s checksum=\$NC"
echo "  FitCachePP_warmhit_mmap epoch0=\${FCOLD}s epoch1=\${FWARM}s checksum=\$FC"
if [ "\$NC" = "\$FC" ] && [ -n "\$NC" ]; then echo "  CHECKSUM_GATE: PASS"; else echo "  CHECKSUM_GATE: FAIL (\$NC / \$FC)"; fi
awk -v n="\$NWARM" -v f="\$FWARM" 'BEGIN{ if (f>0) printf "  warm-epoch speedup (Native/FitCachePP) = %.2fx\n", n/f }'
echo "  cache tier: NVMe (/mnt/bb/\$USER, per-node pre-staged); DRAM tier /tmp"
echo "  result path: \$RESULTS_DIR"
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "megatron warm-hit sweep N=$N_NODES job: $JID -> $JOB_DIR"
