#!/bin/bash
# Megatron mmap COVERAGE / multi-epoch diagnostic, one node.
# Runs FitCachePP then Native_mmap_PFS within ONE job over the SAME shards +
# seed + access plan, then reports per-side metrics and the checksum-equality
# gate. Baseline is Native_mmap_PFS (app's default mmap on PFS, no FitCachePP).
#
# Usage:
#   COVERAGE=0.10 NUM_SHARDS=4 EPOCHS=1 bash scripts/frontier/frontier_llm_coverage_diag.sh
#   EPOCHS=3 COVERAGE=0.25 bash scripts/frontier/frontier_llm_coverage_diag.sh   # multi-epoch reuse
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

COVERAGE="${COVERAGE:-0.10}"
NUM_SHARDS="${NUM_SHARDS:-4}"
N_CHUNKS="${N_CHUNKS:-2000}"
EPOCHS="${EPOCHS:-1}"
SEED="${SEED:-0}"
QOS="${QOS:-debug}"
WALLTIME="${WALLTIME:-00:40:00}"
DATA_DIR="${DATA_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_llm_cov_c${COVERAGE}_e${EPOCHS}
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/llm_coverage/${RUN_TAG}"
mkdir -p "$JOB_DIR"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J llm_cov
#SBATCH -t $WALLTIME
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -q $QOS
#SBATCH -o $JOB_DIR/llm_cov-%j.out
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
set -uo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh
RESULTS_DIR="$JOB_DIR"; cd "\$RESULTS_DIR"

# DRAM tier on /tmp (tmpfs, ~252 GB RAM-backed); NVMe tier on the real
# per-node burst-buffer NVMe /mnt/bb/\$USER (~3.4 TB). Previously both were
# on /tmp, which overflowed the 252 GB tmpfs at the 640 GiB working set
# ("No space left on device") and silently defeated cache reuse.
export BBPATH=/mnt/bb/\$USER
export FitCache_DATA_DIR="$DATA_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_cov_dram
export FitCache_NVME_PATH=/mnt/bb/\$USER/fitcachepp_cov_nvme
export FitCache_DRAM_CAPACITY=\$((100 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((2500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$SERVERS_PER_NODE
export FitCache_CROSS_JOB=0
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

echo "=== starting FitCache servers ==="
srun -N1 -n$SERVERS_PER_NODE --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $SERVERS_PER_NODE > "\$RESULTS_DIR/server.log" 2>&1 &
SPID=\$!
sleep 15

echo "=== RUN A: FitCachePP (LD_PRELOAD) coverage=$COVERAGE epochs=$EPOCHS ==="
srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
  'LD_PRELOAD="\$FITPP_CLIENT_LIB" "\$FITPP_PYTHON_TORCH" "\$FITPP_REPO/benchmarks/megatron/llm_coverage_bench.py" --data-dir "$DATA_DIR" --num-shards $NUM_SHARDS --coverage $COVERAGE --n-chunks $N_CHUNKS --epochs $EPOCHS --seed $SEED' \\
  2>&1 | tee "\$RESULTS_DIR/run_fitcachepp.log"

kill -TERM \$SPID 2>/dev/null || true
sleep 5
# Drop OS page cache effect on the Native side as much as possible by using
# fresh srun (new process); Native side does not use the servers.
echo "=== RUN B: Native_mmap_PFS (no LD_PRELOAD) coverage=$COVERAGE epochs=$EPOCHS ==="
srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
  '"\$FITPP_PYTHON_TORCH" "\$FITPP_REPO/benchmarks/megatron/llm_coverage_bench.py" --data-dir "$DATA_DIR" --num-shards $NUM_SHARDS --coverage $COVERAGE --n-chunks $N_CHUNKS --epochs $EPOCHS --seed $SEED' \\
  2>&1 | tee "\$RESULTS_DIR/run_native.log"

echo "=== COMPARISON (coverage=$COVERAGE epochs=$EPOCHS) ==="
FCK=\$(grep GLOBAL_CHECKSUM "\$RESULTS_DIR/run_fitcachepp.log" | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
NCK=\$(grep GLOBAL_CHECKSUM "\$RESULTS_DIR/run_native.log" | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
FCOLD=\$(grep SUMMARY "\$RESULTS_DIR/run_fitcachepp.log" | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
NCOLD=\$(grep SUMMARY "\$RESULTS_DIR/run_native.log" | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
FAMORT=\$(grep SUMMARY "\$RESULTS_DIR/run_fitcachepp.log" | grep -oE 'amortized_wall=[0-9.]+' | cut -d= -f2)
NAMORT=\$(grep SUMMARY "\$RESULTS_DIR/run_native.log" | grep -oE 'amortized_wall=[0-9.]+' | cut -d= -f2)
echo "checksum: FitCachePP=\$FCK  Native_mmap_PFS=\$NCK"
if [ "\$FCK" = "\$NCK" ] && [ -n "\$FCK" ]; then echo "CHECKSUM_GATE: PASS"; else echo "CHECKSUM_GATE: FAIL"; fi
echo "cold_epoch_wall:  FitCachePP=\${FCOLD}s  Native_mmap_PFS=\${NCOLD}s"
echo "amortized_wall:   FitCachePP=\${FAMORT}s  Native_mmap_PFS=\${NAMORT}s"
awk -v f="\$FCOLD" -v n="\$NCOLD" 'BEGIN{ if (f>0) printf "cold speedup (Native/FitCachePP) = %.2fx\n", n/f }'
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "llm coverage diag job: $JID  coverage=$COVERAGE epochs=$EPOCHS -> $JOB_DIR"
