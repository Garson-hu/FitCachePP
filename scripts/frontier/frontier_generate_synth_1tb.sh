#!/bin/bash
# Generate the sharded 1 TB Megatron-IndexedDataset corpus on Frontier.
#
# Launches a single-node compute job that runs
# benchmarks/megatron/generate_synth_corpus_sharded.py and writes 64
# shard pairs into FITPP_PFS_DATA_ROOT/megatron/synth_1tb_64x16gb/.
#
# Walltime: ~30-40 min single-process; ~10 min with --parallel-workers 4.
# Use QOS=debug (2h cap) to skip the hackathon queue.
#
# Usage:
#   bash scripts/frontier/frontier_generate_synth_1tb.sh
#
# Env knobs:
#   NUM_SHARDS         default 64
#   SHARD_BYTES        default 17179869184 (16 GiB)
#   PARALLEL_WORKERS   default 4
#   OUTPUT_DIR         default $FITPP_PFS_DATA_ROOT/megatron/synth_1tb_64x16gb
#   QOS                default debug
#   WALLTIME           default 01:30:00

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

NUM_SHARDS="${NUM_SHARDS:-64}"
SHARD_BYTES="${SHARD_BYTES:-$((16 * 1024 * 1024 * 1024))}"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-4}"
OUTPUT_DIR="${OUTPUT_DIR:-${FITPP_PFS_DATA_ROOT}/megatron/synth_1tb_64x16gb}"
QOS="${QOS:-debug}"
WALLTIME="${WALLTIME:-01:30:00}"

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_gen_synth_1tb
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/corpus_gen/${RUN_TAG}"
mkdir -p "$JOB_DIR"
mkdir -p "$OUTPUT_DIR"

QOS_LINE=""
[ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J gen_synth_1tb
#SBATCH -t $WALLTIME
#SBATCH -N 1
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/gen_synth_1tb-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

echo "[gen-1tb] output_dir=$OUTPUT_DIR"
echo "[gen-1tb] num_shards=$NUM_SHARDS shard_bytes=$SHARD_BYTES parallel=$PARALLEL_WORKERS"
echo "[gen-1tb] start \$(date)"

srun -N 1 -n 1 --cpus-per-task=8 --cpu-bind=cores \\
     "\$FITPP_PYTHON_TORCH" "\$FITPP_REPO/benchmarks/megatron/generate_synth_corpus_sharded.py" \\
        --output-dir "$OUTPUT_DIR" \\
        --num-shards $NUM_SHARDS \\
        --shard-bytes $SHARD_BYTES \\
        --doc-len 2048 \\
        --parallel-workers $PARALLEL_WORKERS \\
        --skip-existing

echo "[gen-1tb] done \$(date)"
ls -la "$OUTPUT_DIR" | head -8
echo "[gen-1tb] total size:"
du -sh "$OUTPUT_DIR"
EOF

chmod +x "$JOB_DIR/job.sh"
JOB_ID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "corpus-gen job: $JOB_ID -> $JOB_DIR/"
echo "output: $OUTPUT_DIR"
