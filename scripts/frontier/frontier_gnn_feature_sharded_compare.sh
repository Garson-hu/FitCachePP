#!/bin/bash
# Frontier GNN feature-gather benchmark: FitCachePP vs Pure_CF at N_NODES.
#
# Graph-sampler-driven (Option 2) feature gather over the REAL IGB-large
# dataset (paper + author node_feat.npy, paper-paper + paper-author CSR).
# One rank per node; each rank runs gnn_feature_bench.py with a
# rank-distinct sampling seed. Aggregate throughput is the metric.
#
# Submits ONE side per invocation (use SIDES env). QOS=normal default so
# multiple scales can queue; use one high-prio QoS at a time per the
# campaign rule.
#
# Usage:
#   N_NODES=1  SIDES=FitCachePP bash scripts/frontier/frontier_gnn_feature_sharded_compare.sh
#   N_NODES=1  SIDES=Pure_CF    bash scripts/frontier/frontier_gnn_feature_sharded_compare.sh
#
# Env knobs:
#   N_NODES          default 1
#   NUM_BATCHES      default 2000      (sampled subgraph batches per rank)
#   BATCH_SIZE       default 1024      (seed papers per batch)
#   FANOUT_PP        default 12
#   FANOUT_PA        default 8
#   FANOUT_PP2       default 8
#   BLOCK_BYTES      default 12 GiB    (mmap block size; <= node DRAM headroom)
#   COLD_BLOCKS      default 2
#   WARM_BLOCKS      default 2
#   QOS              default normal
#   WALLTIME         default 00:45:00
#   SIDES            default "FitCachePP" (submit one at a time)

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-1}"
NUM_BATCHES="${NUM_BATCHES:-2000}"
BATCH_SIZE="${BATCH_SIZE:-1024}"
FANOUT_PP="${FANOUT_PP:-12}"
FANOUT_PA="${FANOUT_PA:-8}"
FANOUT_PP2="${FANOUT_PP2:-8}"
BLOCK_BYTES="${BLOCK_BYTES:-$((12 * 1024 * 1024 * 1024))}"
COLD_BLOCKS="${COLD_BLOCKS:-2}"
WARM_BLOCKS="${WARM_BLOCKS:-2}"
QOS="${QOS:-normal}"
WALLTIME="${WALLTIME:-00:45:00}"
SIDES_ENV="${SIDES:-FitCachePP}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))

DATA_DIR="${DATA_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/gnn/igb_large_real}"
for req in paper_node_feat.npy author_node_feat.npy \
           paper_cites_paper.csr_indptr.npy paper_cites_paper.csr_indices.npy \
           paper_written_by_author.csr_indptr.npy paper_written_by_author.csr_indices.npy; do
  if [ ! -f "$DATA_DIR/$req" ]; then
    echo "ERROR: missing $DATA_DIR/$req (run build_igb_csr.py first)" >&2
    exit 1
  fi
done
echo "[driver] GNN data verified at $DATA_DIR"

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_gnn_feat_N${N_NODES}
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/gnn_feature_sharded/${RUN_TAG}"
mkdir -p "$ROOT_DIR"
QOS_LINE=""
[ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

submit_side() {
  local SIDE="$1"
  local JOB_DIR="$ROOT_DIR/${SIDE}"
  mkdir -p "$JOB_DIR"
  local USE_LD_PRELOAD=""
  local CACHE_SUBDIR="${SIDE}_${RUN_TAG}"
  if [ "$SIDE" = "FitCachePP" ]; then
    USE_LD_PRELOAD='LD_PRELOAD="$FITPP_CLIENT_LIB"'
  fi

  cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J gnn_${SIDE}
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/gnn_${SIDE}-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
set -uo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="$JOB_DIR"
mkdir -p "\$RESULTS_DIR"; cd "\$RESULTS_DIR"

export BBPATH=/tmp
export FitCache_DATA_DIR="$DATA_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_gnn_${CACHE_SUBDIR}_dram
export FitCache_NVME_PATH=/tmp/fitcachepp_gnn_${CACHE_SUBDIR}_nvme
export FitCache_DRAM_CAPACITY=\$((40 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$TOTAL_SERVERS
export FitCache_CROSS_JOB=0
export FITPP_TIMING_DUMP_ON_EXIT=1
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

echo "[$SIDE] N_NODES=$N_NODES servers=$TOTAL_SERVERS num_batches=$NUM_BATCHES batch=$BATCH_SIZE"
echo "[$SIDE] fanout pp=$FANOUT_PP pa=$FANOUT_PA pp2=$FANOUT_PP2 block_bytes=$BLOCK_BYTES"
echo "[$SIDE] data=$DATA_DIR"

echo "[$SIDE] launching $TOTAL_SERVERS servers"
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE \\
     --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS \\
     > "\$RESULTS_DIR/server_\${SLURM_JOB_ID}.log" 2>&1 &
SERVER_SRUN_PID=\$!
sleep 15

WRAPPER="\$RESULTS_DIR/run_bench.sh"
cat > "\$WRAPPER" <<'WEOF'
#!/bin/bash
${USE_LD_PRELOAD} "\$FITPP_PYTHON_TORCH" \\
    "\$FITPP_REPO/benchmarks/gnn/gnn_feature_bench.py" \\
    --data-dir "$DATA_DIR" \\
    --num-batches $NUM_BATCHES \\
    --batch-size $BATCH_SIZE \\
    --fanout-pp $FANOUT_PP --fanout-pa $FANOUT_PA --fanout-pp2 $FANOUT_PP2 \\
    --block-bytes $BLOCK_BYTES \\
    --cold-blocks $COLD_BLOCKS --warm-blocks $WARM_BLOCKS
WEOF
chmod +x "\$WRAPPER"

echo "=== $SIDE start \$(date) ==="
START=\$SECONDS
srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 \\
     --cpu-bind=cores "\$WRAPPER" 2>&1 | tee "\$RESULTS_DIR/bench_\${SLURM_JOB_ID}.log"
END=\$SECONDS
echo "=== $SIDE done \$(date) wall=\$((END-START))s ==="

kill -TERM \$SERVER_SRUN_PID 2>/dev/null || true
sleep 3
echo "----- $SIDE summary (N_NODES=$N_NODES) -----"
grep -E "amortized:|rank=.* cold:|rank=.* warm:" "\$RESULTS_DIR/bench_\${SLURM_JOB_ID}.log" || true
EOF
  chmod +x "$JOB_DIR/job.sh"
  sbatch --parsable "$JOB_DIR/job.sh"
}

JOB=""
case " $SIDES_ENV " in *" FitCachePP "*) JOB=$(submit_side FitCachePP); echo "FitCachePP: $JOB -> $ROOT_DIR/FitCachePP/";; esac
case " $SIDES_ENV " in *" Pure_CF "*)    JOB=$(submit_side Pure_CF);    echo "Pure_CF: $JOB -> $ROOT_DIR/Pure_CF/";; esac

cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
n_nodes=$N_NODES
sides=$SIDES_ENV
num_batches=$NUM_BATCHES
batch_size=$BATCH_SIZE
fanout_pp=$FANOUT_PP fanout_pa=$FANOUT_PA fanout_pp2=$FANOUT_PP2
block_bytes=$BLOCK_BYTES
cold_blocks=$COLD_BLOCKS warm_blocks=$WARM_BLOCKS
data_dir=$DATA_DIR
qos=$QOS walltime=$WALLTIME
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
