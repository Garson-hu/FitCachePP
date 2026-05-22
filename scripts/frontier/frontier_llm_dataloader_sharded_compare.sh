#!/bin/bash
# Frontier sharded 1 TB Megatron-IndexedDataset LLM dataloader compare:
# FitCachePP vs Pure_CF at N_NODES scale.
#
# Difference from frontier_llm_dataloader_compare.sh (which targets the
# single-file 10 GB IndexedDataset):
#   - Operates on a sharded corpus produced by
#     frontier_generate_synth_1tb.sh (default 64 shards x 16 GiB).
#   - Each rank is assigned a partition of the shards via rank-stride
#     selection inside llm_dataloader_bench_sharded.py.
#   - One rank per node; multiple nodes run different shard partitions
#     concurrently. Aggregate throughput is reported per rank.
#   - Iteration loop ACTUALLY TOUCHES the token bytes (np.sum on
#     uint16 view) so the measurement reflects real data access, not
#     zero-copy view construction.
#
# Submits TWO sbatches (FitCachePP + Pure_CF). Each runs N_NODES nodes
# with 1 rank per node. The FitCache server runs 4 servers per node;
# Pure_CF spawns servers too but skips LD_PRELOAD so they go unused.
#
# Usage:
#   N_NODES=1  bash scripts/frontier/frontier_llm_dataloader_sharded_compare.sh
#   N_NODES=4  bash scripts/frontier/frontier_llm_dataloader_sharded_compare.sh
#   N_NODES=16 bash scripts/frontier/frontier_llm_dataloader_sharded_compare.sh
#
# Env knobs:
#   N_NODES            default 1
#   ITERS_PER_SHARD    default 10000
#   BATCH_SIZE         default 16
#   SEQ_LENGTH         default 1024
#   COLD_SHARDS        default 4
#   WARM_SHARDS        default 4
#   NUM_SHARDS         default 64
#   DATA_DIR           default $FITPP_PFS_DATA_ROOT/megatron/synth_1tb_64x16gb
#   QOS                default debug   (2h cap; use hackathon if it doesn't fit)
#   WALLTIME           default 00:45:00
#   SIDES              default "FitCachePP Pure_CF"

set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-1}"
NUM_SHARDS="${NUM_SHARDS:-64}"
ITERS_PER_SHARD="${ITERS_PER_SHARD:-10000}"
BATCH_SIZE="${BATCH_SIZE:-16}"
SEQ_LENGTH="${SEQ_LENGTH:-1024}"
COLD_SHARDS="${COLD_SHARDS:-4}"
WARM_SHARDS="${WARM_SHARDS:-4}"
DATA_DIR="${DATA_DIR:-${FITPP_PFS_DATA_ROOT}/megatron/synth_1tb_64x16gb}"
QOS="${QOS:-debug}"
WALLTIME="${WALLTIME:-00:45:00}"
SIDES_ENV="${SIDES:-FitCachePP Pure_CF}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))

if [ ! -d "$DATA_DIR" ]; then
    echo "ERROR: corpus dir missing: $DATA_DIR" >&2
    echo "       run scripts/frontier/frontier_generate_synth_1tb.sh first" >&2
    exit 1
fi
SHARD_COUNT=$(ls "$DATA_DIR"/shard_*.bin 2>/dev/null | wc -l)
if [ "$SHARD_COUNT" -lt "$NUM_SHARDS" ]; then
    echo "ERROR: expected $NUM_SHARDS shards in $DATA_DIR, found $SHARD_COUNT" >&2
    exit 1
fi
echo "[driver] corpus: $DATA_DIR ($SHARD_COUNT shards)"

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_llm_sharded_N${N_NODES}
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/llm_dataloader_sharded/${RUN_TAG}"
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
#SBATCH -J llm_sharded_${SIDE}
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $FITPP_SLURM_PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/llm_sharded_${SIDE}-%j.out

export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO

set -euo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

RESULTS_DIR="$JOB_DIR"
mkdir -p "\$RESULTS_DIR"
cd "\$RESULTS_DIR"

export BBPATH=/tmp
export FitCache_DATA_DIR="$DATA_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_llmsh_${CACHE_SUBDIR}_dram
export FitCache_NVME_PATH=/tmp/fitcachepp_llmsh_${CACHE_SUBDIR}_nvme
# Cache capacities sized to hold each rank's share of the corpus
# in node-local NVMe. At N_NODES=$N_NODES with 64 shards of 16 GiB,
# each rank handles 64/$N_NODES shards (at N<=64), i.e. up to
# $((NUM_SHARDS * 16 / N_NODES)) GiB per rank.
export FitCache_DRAM_CAPACITY=\$((40 * 1024 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((1500 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$TOTAL_SERVERS
export FitCache_CROSS_JOB=0
export FITPP_TIMING_DUMP_ON_EXIT=1
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

echo "[$SIDE] N_NODES=$N_NODES  total_servers=$TOTAL_SERVERS  num_shards=$NUM_SHARDS"
echo "[$SIDE] iters_per_shard=$ITERS_PER_SHARD batch=$BATCH_SIZE seq=$SEQ_LENGTH"
echo "[$SIDE] cold/warm shards = $COLD_SHARDS / $WARM_SHARDS"
echo "[$SIDE] corpus=$DATA_DIR"

echo "[$SIDE] launching $TOTAL_SERVERS servers via srun"
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
    "\$FITPP_REPO/benchmarks/megatron/llm_dataloader_bench_sharded.py" \\
    --data-dir "$DATA_DIR" \\
    --num-shards $NUM_SHARDS \\
    --iters-per-shard $ITERS_PER_SHARD \\
    --batch-size $BATCH_SIZE \\
    --seq-length $SEQ_LENGTH \\
    --cold-shards $COLD_SHARDS \\
    --warm-shards $WARM_SHARDS
WEOF
chmod +x "\$WRAPPER"

echo "=== $SIDE start \$(date) ==="
START=\$SECONDS
srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 \\
     --cpu-bind=cores "\$WRAPPER" \\
     2>&1 | tee "\$RESULTS_DIR/bench_\${SLURM_JOB_ID}.log"
END=\$SECONDS
ELAPSED=\$((END - START))
echo "=== $SIDE done \$(date) wall=\${ELAPSED}s ==="

kill -TERM \$SERVER_SRUN_PID 2>/dev/null || true
sleep 3

OPEN_RPC=\$(grep -cE "Open RPC: requested path" "\$RESULTS_DIR"/fitcache_server_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
MMAP=\$(grep -cE "mmap on tracked fd|mmap: redirected to anon" "\$RESULTS_DIR"/fitcache_intercept_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END {print s+0}')
echo "----- $SIDE summary (N_NODES=$N_NODES) -----"
echo "  Wall:            \${ELAPSED}s"
echo "  Open RPCs:       \$OPEN_RPC"
echo "  mmap-redirects:  \$MMAP"
grep -E "^\\[bench-sharded\\] rank=.*amortized:|^\\[bench-sharded\\] rank=.*cold:|^\\[bench-sharded\\] rank=.*warm:" \\
     "\$RESULTS_DIR/bench_\${SLURM_JOB_ID}.log" || true
EOF
    chmod +x "$JOB_DIR/job.sh"
    sbatch --parsable "$JOB_DIR/job.sh"
}

JOB_FCP=""
JOB_PCF=""
case " $SIDES_ENV " in
    *" FitCachePP "*) JOB_FCP=$(submit_side FitCachePP) ;;
esac
case " $SIDES_ENV " in
    *" Pure_CF "*)    JOB_PCF=$(submit_side Pure_CF) ;;
esac
[ -n "$JOB_FCP" ] && echo "FitCachePP run: $JOB_FCP -> $ROOT_DIR/FitCachePP/"
[ -n "$JOB_PCF" ] && echo "Pure_CF    run: $JOB_PCF -> $ROOT_DIR/Pure_CF/"

cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
fitcachepp_job=${JOB_FCP:-(not submitted)}
purecf_job=${JOB_PCF:-(not submitted)}
n_nodes=$N_NODES
num_shards=$NUM_SHARDS
iters_per_shard=$ITERS_PER_SHARD
batch_size=$BATCH_SIZE
seq_length=$SEQ_LENGTH
cold_shards=$COLD_SHARDS
warm_shards=$WARM_SHARDS
data_dir=$DATA_DIR
servers_per_node=$SERVERS_PER_NODE
qos=$QOS
walltime=$WALLTIME
EOF
echo "Manifest at $ROOT_DIR/manifest.txt"
