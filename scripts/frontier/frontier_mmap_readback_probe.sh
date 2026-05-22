#!/bin/bash
# Within-one-job FitCachePP-vs-Pure_CF mmap read-back correctness probe.
# Starts FitCache servers, runs the probe under LD_PRELOAD (FitCachePP),
# then kills servers and runs the SAME probe without LD_PRELOAD (Pure_CF).
# The two GLOBAL_CHECKSUM lines MUST match. A mismatch = FitCachePP mmap
# read corruption/truncation.
#
# Usage: TARGET=<file> bash scripts/frontier/frontier_mmap_readback_probe.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

TARGET="${TARGET:-/lustre/orion/gen008/proj-shared/ghu4/data/gnn/igb_large_real/paper_cites_paper.csr_indices.npy}"
SLICE_MB="${SLICE_MB:-4}"
N_SLICES="${N_SLICES:-48}"
QOS="${QOS:-debug}"
WALLTIME="${WALLTIME:-00:30:00}"
DATA_DIR="$(dirname "$TARGET")"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_mmap_probe
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/mmap_probe/${RUN_TAG}"
mkdir -p "$JOB_DIR"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J mmap_probe
#SBATCH -t $WALLTIME
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
#SBATCH -q $QOS
#SBATCH -o $JOB_DIR/mmap_probe-%j.out
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
set -uo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh
RESULTS_DIR="$JOB_DIR"; cd "\$RESULTS_DIR"

export BBPATH=/tmp
export FitCache_DATA_DIR="$DATA_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_probe_dram
export FitCache_NVME_PATH=/tmp/fitcachepp_probe_nvme
export FitCache_DRAM_CAPACITY=\$((40 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=4
export FitCache_CROSS_JOB=0
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

echo "=== starting FitCache servers ==="
srun -N1 -n4 --ntasks-per-node=4 --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" 4 > "\$RESULTS_DIR/server.log" 2>&1 &
SPID=\$!
sleep 15

echo "=== PROBE A: FitCachePP (LD_PRELOAD) ==="
srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
  'LD_PRELOAD="\$FITPP_CLIENT_LIB" "\$FITPP_PYTHON_TORCH" "\$FITPP_REPO/benchmarks/gnn/mmap_readback_probe.py" --path "$TARGET" --slice-mb $SLICE_MB --n-slices $N_SLICES' \\
  2>&1 | tee "\$RESULTS_DIR/probe_fcp.log"

kill -TERM \$SPID 2>/dev/null || true
sleep 5

echo "=== PROBE B: Pure_CF (no LD_PRELOAD) ==="
srun -N1 -n1 -c8 --cpu-bind=cores bash -c \\
  '"\$FITPP_PYTHON_TORCH" "\$FITPP_REPO/benchmarks/gnn/mmap_readback_probe.py" --path "$TARGET" --slice-mb $SLICE_MB --n-slices $N_SLICES' \\
  2>&1 | tee "\$RESULTS_DIR/probe_pcf.log"

echo "=== COMPARISON ==="
FCP=\$(grep GLOBAL_CHECKSUM "\$RESULTS_DIR/probe_fcp.log" | grep -oE '[0-9]+\$')
PCF=\$(grep GLOBAL_CHECKSUM "\$RESULTS_DIR/probe_pcf.log" | grep -oE '[0-9]+\$')
echo "FitCachePP GLOBAL_CHECKSUM = \$FCP"
echo "Pure_CF    GLOBAL_CHECKSUM = \$PCF"
if [ "\$FCP" = "\$PCF" ]; then echo "RESULT: MATCH (FitCachePP mmap read is correct)"; else echo "RESULT: MISMATCH (FitCachePP mmap read is WRONG)"; fi
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "mmap probe job: $JID -> $JOB_DIR  (target=$TARGET)"
