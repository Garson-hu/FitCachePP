#!/bin/bash
# Smallest prototype: does DIRECT mmap of a local cached NVMe file beat
# Native_mmap_PFS? Isolates "mmap from local NVMe" from "FitCache's
# server+Mercury-bulk populate path".
#
# Three paths compared over the SAME shards + seed + access plan:
#   a. Native_mmap_PFS         : numpy.memmap on the Lustre/PFS original.
#   b. FitCachePP_server_mmap  : current path (LD_PRELOAD + server eager
#                                populate via Mercury bulk into anon memory).
#   c. Direct_local_cache_mmap : numpy.memmap of a cached copy on /mnt/bb/$USER
#                                (real mmap, kernel page-faults from local NVMe;
#                                NO Mercury, NO server).
# Both SPARSE (coverage 0.05) and DENSE (coverage 1.0) access. Checksum
# equality is a hard gate across all three.
#
# Usage: NUM_SHARDS=2 bash scripts/frontier/frontier_mmap_local_cache_prototype.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

NUM_SHARDS="${NUM_SHARDS:-2}"
N_CHUNKS="${N_CHUNKS:-2000}"
SEED="${SEED:-0}"
QOS="${QOS:-debug}"
WALLTIME="${WALLTIME:-00:55:00}"
PFS_DIR="${PFS_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_mmap_localcache_proto
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/mmap_localcache_proto/${RUN_TAG}"
mkdir -p "$JOB_DIR"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J mmap_proto
#SBATCH -t $WALLTIME
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -q $QOS
#SBATCH -o $JOB_DIR/mmap_proto-%j.out
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
set -uo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh
RESULTS_DIR="$JOB_DIR"; cd "\$RESULTS_DIR"
BENCH="\$FITPP_REPO/benchmarks/megatron/llm_coverage_bench.py"
PY="\$FITPP_PYTHON_TORCH"

# --- stage shards to local NVMe (one-time warm-cache populate, timed) ---
CACHE_DIR=/mnt/bb/\$USER/proto_cached
mkdir -p "\$CACHE_DIR"
echo "=== staging $NUM_SHARDS shards PFS -> local NVMe (\$CACHE_DIR) ==="
STAGE_START=\$SECONDS
for i in \$(seq 0 \$(($NUM_SHARDS - 1))); do
  f=\$(printf "shard_%04d.bin" \$i)
  if [ ! -f "\$CACHE_DIR/\$f" ]; then
    cp "$PFS_DIR/\$f" "\$CACHE_DIR/\$f"
  fi
done
STAGE_WALL=\$((SECONDS - STAGE_START))
STAGE_BYTES=\$(du -sb "\$CACHE_DIR" | awk '{print \$1}')
echo "staged \$STAGE_BYTES bytes in \${STAGE_WALL}s ( \$(awk -v b=\$STAGE_BYTES -v t=\$STAGE_WALL 'BEGIN{if(t>0)printf "%.0f", b/t/1024/1024}') MB/s PFS->NVMe copy )"

# --- FitCache servers (only needed for path b) ---
export BBPATH=/mnt/bb/\$USER
export FitCache_DATA_DIR="$PFS_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_proto_dram
export FitCache_NVME_PATH=/mnt/bb/\$USER/fitcachepp_proto_nvme
export FitCache_DRAM_CAPACITY=\$((40 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$SERVERS_PER_NODE
export FitCache_CROSS_JOB=0
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"
srun -N1 -n$SERVERS_PER_NODE --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $SERVERS_PER_NODE > "\$RESULTS_DIR/server.log" 2>&1 &
SPID=\$!
sleep 15

run_path () {
  local label="\$1"; local cov="\$2"; local datadir="\$3"; local preload="\$4"; local logf="\$5"
  echo "=== \$label  coverage=\$cov  data-dir=\$datadir  preload=\${preload:-none} ==="
  if [ -n "\$preload" ]; then
    srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
      "LD_PRELOAD=\"\$preload\" \"\$PY\" \"\$BENCH\" --data-dir \"\$datadir\" --num-shards $NUM_SHARDS --coverage \$cov --n-chunks $N_CHUNKS --epochs 1 --seed $SEED --label \"\$label\"" \\
      2>&1 | tee "\$RESULTS_DIR/\$logf"
  else
    srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
      "\"\$PY\" \"\$BENCH\" --data-dir \"\$datadir\" --num-shards $NUM_SHARDS --coverage \$cov --n-chunks $N_CHUNKS --epochs 1 --seed $SEED --label \"\$label\"" \\
      2>&1 | tee "\$RESULTS_DIR/\$logf"
  fi
}

for COV in 0.05 1.0; do
  run_path "Native_mmap_PFS"        \$COV "$PFS_DIR"  ""                     "run_native_pfs_c\${COV}.log"
  run_path "Direct_local_cache_mmap" \$COV "\$CACHE_DIR" ""                  "run_direct_nvme_c\${COV}.log"
  run_path "FitCachePP_server_mmap"  \$COV "$PFS_DIR"  "\$FITPP_CLIENT_LIB"  "run_fitcachepp_c\${COV}.log"
done

kill -TERM \$SPID 2>/dev/null || true
sleep 3

echo ""
echo "==================== PROTOTYPE SUMMARY ===================="
echo "PFS->NVMe stage: \${STAGE_WALL}s for \$STAGE_BYTES bytes"
for COV in 0.05 1.0; do
  echo "--- coverage=\$COV ---"
  for tag in Native_mmap_PFS Direct_local_cache_mmap FitCachePP_server_mmap; do
    case \$tag in
      Native_mmap_PFS) lf="run_native_pfs_c\${COV}.log";;
      Direct_local_cache_mmap) lf="run_direct_nvme_c\${COV}.log";;
      FitCachePP_server_mmap) lf="run_fitcachepp_c\${COV}.log";;
    esac
    line=\$(grep "SUMMARY" "\$RESULTS_DIR/\$lf" 2>/dev/null | head -1)
    cold=\$(echo "\$line" | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
    ck=\$(echo "\$line" | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
    printf "  %-26s cold_wall=%ss checksum=%s\n" "\$tag" "\$cold" "\$ck"
  done
  # checksum gate across the three
  c1=\$(grep "SUMMARY" "\$RESULTS_DIR/run_native_pfs_c\${COV}.log" 2>/dev/null | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
  c2=\$(grep "SUMMARY" "\$RESULTS_DIR/run_direct_nvme_c\${COV}.log" 2>/dev/null | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
  c3=\$(grep "SUMMARY" "\$RESULTS_DIR/run_fitcachepp_c\${COV}.log" 2>/dev/null | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
  if [ "\$c1" = "\$c2" ] && [ "\$c2" = "\$c3" ] && [ -n "\$c1" ]; then echo "  CHECKSUM_GATE: PASS"; else echo "  CHECKSUM_GATE: FAIL (\$c1 / \$c2 / \$c3)"; fi
done
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "mmap local-cache prototype job: $JID -> $JOB_DIR"
