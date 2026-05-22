#!/bin/bash
# Validate the warm-hit direct-local-NVMe mmap redesign in ISOLATION from
# server-side promotion (which currently does not populate the cache for the
# mmap/fd-reuse workload — separate bug P2). We PRE-STAGE the cache at the
# exact deterministic hash-bin path the client resolver checks, so every mmap
# is a guaranteed warm hit, then compare FitCachePP (warm-hit direct NVMe
# mmap) vs Native_mmap_PFS at sparse + dense coverage. Checksum gate hard.
#
# Usage: NUM_SHARDS=4 bash scripts/frontier/frontier_warmhit_validate.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

NUM_SHARDS="${NUM_SHARDS:-4}"
N_CHUNKS="${N_CHUNKS:-2000}"
SEED="${SEED:-0}"
QOS="${QOS:-debug}"
WALLTIME="${WALLTIME:-00:45:00}"
PFS_DIR="${PFS_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_warmhit_validate
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/warmhit_validate/${RUN_TAG}"
mkdir -p "$JOB_DIR"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J warmhit_val
#SBATCH -t $WALLTIME
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -q $QOS
#SBATCH -o $JOB_DIR/warmhit_val-%j.out
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

# Cache tiers (same as coverage launcher): NVMe tier on /mnt/bb.
export BBPATH=/mnt/bb/\$USER
export FitCache_DATA_DIR="$PFS_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_wh_dram
export FitCache_NVME_PATH=/mnt/bb/\$USER/fitcachepp_wh_nvme
export FitCache_DRAM_CAPACITY=\$((40 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((2000 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$SERVERS_PER_NODE
export FitCache_CROSS_JOB=0
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

echo "=== PRE-STAGE cache: $NUM_SHARDS shards -> NVMe tier at hash-bin path ==="
STAGE_START=\$SECONDS
for i in \$(seq 0 \$(($NUM_SHARDS - 1))); do
  src=\$(printf "$PFS_DIR/shard_%04d.bin" \$i)
  dst=\$("\$TOOL" "\$src" "\$FitCache_NVME_PATH")
  mkdir -p "\$(dirname "\$dst")"
  if [ ! -f "\$dst" ] || [ "\$(stat -c %s "\$dst" 2>/dev/null||echo 0)" != "\$(stat -c %s "\$src")" ]; then
    cp "\$src" "\$dst"
  fi
  echo "  staged shard_\$(printf %04d \$i) -> \$dst (\$(stat -c %s "\$dst") bytes)"
done
echo "stage wall=\$((SECONDS - STAGE_START))s"

# Servers (the bench still issues open RPCs; warm-hit path doesn't need them
# but we keep the env realistic).
srun -N1 -n$SERVERS_PER_NODE --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $SERVERS_PER_NODE > "\$RESULTS_DIR/server.log" 2>&1 &
SPID=\$!
sleep 15

run () { # label coverage preload logf
  echo "=== \$1  coverage=\$2  preload=\${3:-none} ==="
  if [ -n "\$3" ]; then
    srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
      "LD_PRELOAD=\"\$3\" \"\$PY\" \"\$BENCH\" --data-dir \"$PFS_DIR\" --num-shards $NUM_SHARDS --coverage \$2 --n-chunks $N_CHUNKS --epochs 1 --seed $SEED --label \"\$1\"" \\
      2>&1 | tee "\$RESULTS_DIR/\$4"
  else
    srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
      "\"\$PY\" \"\$BENCH\" --data-dir \"$PFS_DIR\" --num-shards $NUM_SHARDS --coverage \$2 --n-chunks $N_CHUNKS --epochs 1 --seed $SEED --label \"\$1\"" \\
      2>&1 | tee "\$RESULTS_DIR/\$4"
  fi
}

for COV in 0.05 1.0; do
  run "Native_mmap_PFS"          \$COV ""                    "native_c\${COV}.log"
  run "FitCachePP_warmhit_mmap"  \$COV "\$FITPP_CLIENT_LIB"  "fitcachepp_c\${COV}.log"
done

kill -TERM \$SPID 2>/dev/null || true; sleep 3

echo ""
echo "==================== WARM-HIT VALIDATION SUMMARY ===================="
for COV in 0.05 1.0; do
  echo "--- coverage=\$COV ---"
  NW=\$(grep SUMMARY "\$RESULTS_DIR/native_c\${COV}.log" 2>/dev/null | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
  FW=\$(grep SUMMARY "\$RESULTS_DIR/fitcachepp_c\${COV}.log" 2>/dev/null | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
  NC=\$(grep SUMMARY "\$RESULTS_DIR/native_c\${COV}.log" 2>/dev/null | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
  FC=\$(grep SUMMARY "\$RESULTS_DIR/fitcachepp_c\${COV}.log" 2>/dev/null | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
  echo "  Native_mmap_PFS         wall=\${NW}s checksum=\$NC"
  echo "  FitCachePP_warmhit_mmap wall=\${FW}s checksum=\$FC"
  if [ "\$NC" = "\$FC" ] && [ -n "\$NC" ]; then echo "  CHECKSUM_GATE: PASS"; else echo "  CHECKSUM_GATE: FAIL"; fi
  awk -v n="\$NW" -v f="\$FW" 'BEGIN{ if (f>0) printf "  speedup (Native/FitCachePP) = %.2fx\n", n/f }'
done
echo "=== WARM HIT confirmations from intercept log (DEBUG may be off) ==="
grep -c "WARM HIT" "\$RESULTS_DIR"/fitcache_intercept_log.*.* 2>/dev/null | head
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "warm-hit validation job: $JID -> $JOB_DIR"
