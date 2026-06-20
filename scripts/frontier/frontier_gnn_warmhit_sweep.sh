#!/bin/bash
# GNN graph-sampler-driven feature-gather mmap benchmark on real IGB-large.
# Validates the warm-hit DIRECT LOCAL-NVMe mmap path for a 2-hop heterogeneous
# feature-loading workload: FitCachePP (warm-hit direct mmap of pre-staged
# cached file) vs Native_mmap_PFS (plain numpy.memmap of the PFS file).
#
# NOT full GNN training: no model, no backward pass. Claim is limited to
# mmap-backed GNN FEATURE LOADING under sampler-driven feature-gather.
#
# Design (mirrors the Megatron warm-hit sweep): every node pre-stages the
# feature + CSR files to its own node-local NVMe (/mnt/bb/$USER) at the
# resolver's deterministic hash-bin path, so every FitCachePP feature mmap is
# a guaranteed warm hit served from local NVMe. This isolates the warm-hit
# DIRECT-MMAP mechanism from cross-node server-routing. The pre-stage cost is
# reported separately (NOT charged as a cold epoch). Each rank samples with a
# rank-distinct seed so ranks gather disjoint-ish node sets.
#
# Checksum equality (FitCachePP vs Native_mmap_PFS, same seed + access plan)
# is a HARD gate.
#
# Usage: N_NODES=1 NUM_BATCHES=150 bash scripts/frontier/frontier_gnn_warmhit_sweep.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-1}"
NUM_BATCHES="${NUM_BATCHES:-150}"
BATCH_SIZE="${BATCH_SIZE:-1024}"
FANOUT_PP="${FANOUT_PP:-12}"
FANOUT_PA="${FANOUT_PA:-8}"
FANOUT_PP2="${FANOUT_PP2:-8}"
BLOCK_BYTES="${BLOCK_BYTES:-$((12 * 1024 * 1024 * 1024))}"
EPOCHS="${EPOCHS:-2}"
SEED="${SEED:-0}"
# PREFETCH_1X=1: replace cp-prestaging with the application prefetch() hint.
# GNN is un-partitionable (the 2-hop gather can touch any feature row), so each
# node still prefetch-promotes the WHOLE feat+CSR set -> stays N x (1x N/A); but
# this exercises the same mmap+prefetch path as Megatron/DINOv2 and the resolver
# only warm-hits a file once it is fully local, fixing the partial-stage checksum
# mismatch the cp path showed at some N. Feature files are 889 GB -> long wait.
PREFETCH_1X="${PREFETCH_1X:-0}"
if [ "$PREFETCH_1X" = "1" ]; then
  PREFETCH_ENV="FITCACHE_PREFETCH=1 FITCACHE_PREFETCH_WAIT_SEC=${PREFETCH_WAIT_SEC:-1800} "
else
  PREFETCH_ENV=""
fi
QOS="${QOS:-debug}"
# Partition override: e.g. PARTITION=g1 to use the g1 partition (full compute
# nodes w/ NVMe, AllowQos=ALL, often many idle nodes -> skips the batch queue).
# When PARTITION!=batch, leave QOS empty to take the partition's default QoS.
PARTITION="${PARTITION:-$FITPP_SLURM_PARTITION}"
WALLTIME="${WALLTIME:-01:45:00}"
DATA_DIR="${DATA_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/gnn/igb_large_real}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_gnn_warmhit_N${N_NODES}
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/gnn_warmhit_sweep/${RUN_TAG}"
mkdir -p "$JOB_DIR"
QOS_LINE=""; [ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J gnn_wh_N${N_NODES}
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/gnn_wh-%j.out
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
set -uo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh
RESULTS_DIR="$JOB_DIR"; cd "\$RESULTS_DIR"
BENCH="\$FITPP_REPO/benchmarks/gnn/gnn_feature_bench.py"
PY="\$FITPP_PYTHON_TORCH"
TOOL="\$FITPP_REPO/tools/fitcache_cached_path"

export BBPATH=/mnt/bb/\$USER
export FitCache_DATA_DIR="$DATA_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_gnn_dram
export FitCache_NVME_PATH=/mnt/bb/\$USER/fitcachepp_gnn_nvme
# DRAM cap tiny on purpose: every pre-staged file (incl. small CSR) then
# resolves on the NVMe tier where stage.sh put it, and the server's open-time
# promotion targets NVMe where the dst already exists (fs::copy no-ops via the
# exists-throw), so there is no redundant re-copy of the 410/479 GB features.
export FitCache_DRAM_CAPACITY=\$((256 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((3000 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$TOTAL_SERVERS
export FitCache_CROSS_JOB=0
export PREFETCH_1X=$PREFETCH_1X

# Files to pre-stage to node-local NVMe at the resolver hash-bin path. Feature
# files give warm-hit feature gather; CSR files keep the sampler reads local
# and fast (and identical on both sides). Resolver gate = full-size match, so
# whole files must be staged. Paths baked at generation; staged on every node.
export STAGE_FILES="$DATA_DIR/paper_node_feat.npy $DATA_DIR/author_node_feat.npy $DATA_DIR/paper_cites_paper.csr_indptr.npy $DATA_DIR/paper_cites_paper.csr_indices.npy $DATA_DIR/paper_written_by_author.csr_indptr.npy $DATA_DIR/paper_written_by_author.csr_indices.npy"
if [ "\$PREFETCH_1X" != "1" ]; then
echo "=== PRE-STAGE on all $N_NODES nodes (paper+author feat + CSR) ==="
STAGE_START=\$SECONDS
srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpu-bind=cores bash -c '
  mkdir -p "\$FitCache_NVME_PATH"
  for f in \$STAGE_FILES; do
    dst=\$("\$FITPP_REPO/tools/fitcache_cached_path" "\$f" "\$FitCache_NVME_PATH")
    mkdir -p "\$(dirname "\$dst")"
    if [ ! -f "\$dst" ] || [ "\$(stat -c %s "\$dst" 2>/dev/null || echo 0)" != "\$(stat -c %s "\$f")" ]; then
      cp "\$f" "\$dst"
    fi
  done
  echo "[stage] \$(hostname): \$(du -sb "\$FitCache_NVME_PATH" | cut -f1) bytes staged"
'
echo "stage wall=\$((SECONDS - STAGE_START))s"
else
  echo "=== PREFETCH_1X: skip cp-prestage; FitCachePP arm prefetch-promotes the whole feat+CSR set (un-partitionable -> N x) ==="
  srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpu-bind=cores bash -c 'mkdir -p "\$FitCache_NVME_PATH"'
fi

mkdir -p "\$FitCache_DRAM_PATH"
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS > "\$RESULTS_DIR/server.log" 2>&1 &
SPID=\$!
sleep 15

run () { # label preload logf
  echo "=== \$1 (N=$N_NODES, $NUM_BATCHES batches, $EPOCHS ep) ==="
  if [ -n "\$2" ]; then
    srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \\
      "${PREFETCH_ENV}LD_PRELOAD=\"\$2\" \"\$PY\" \"\$BENCH\" --data-dir \"$DATA_DIR\" --num-batches $NUM_BATCHES --batch-size $BATCH_SIZE --fanout-pp $FANOUT_PP --fanout-pa $FANOUT_PA --fanout-pp2 $FANOUT_PP2 --block-bytes $BLOCK_BYTES --epochs $EPOCHS --seed $SEED --label \"\$1\"" \\
      2>&1 | tee "\$RESULTS_DIR/\$3"
  else
    srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \\
      "\"\$PY\" \"\$BENCH\" --data-dir \"$DATA_DIR\" --num-batches $NUM_BATCHES --batch-size $BATCH_SIZE --fanout-pp $FANOUT_PP --fanout-pa $FANOUT_PA --fanout-pp2 $FANOUT_PP2 --block-bytes $BLOCK_BYTES --epochs $EPOCHS --seed $SEED --label \"\$1\"" \\
      2>&1 | tee "\$RESULTS_DIR/\$3"
  fi
}

run "Native_mmap_PFS"  ""                   "native.log"
run "FitCachePP"       "\$FITPP_CLIENT_LIB"  "fitcachepp.log"

echo "=== per-node cache footprint (GNN is un-partitionable: each node holds the whole feat+CSR set = N x) ==="
srun --overlap -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpu-bind=cores \\
  bash -c 'echo "[cache] node=\$SLURM_NODEID host=\$(hostname) bytes=\$(du -sb "\$FitCache_NVME_PATH" 2>/dev/null | cut -f1)"' 2>&1 | sort

kill -TERM \$SPID 2>/dev/null || true; sleep 3

echo ""
echo "==================== GNN WARM-HIT SWEEP SUMMARY (N=$N_NODES) ===================="
# Representative walls = rank 0 (every rank does equivalent per-node work). Use
# the rank=0 line SPECIFICALLY (not head -1): each rank samples seed+rank so
# every rank has a DIFFERENT checksum, and the logs interleave ranks, so head
# -1 could pick different ranks from the two logs.
NS=\$(grep "GNN-SUMMARY" "\$RESULTS_DIR/native.log" 2>/dev/null | grep "rank=0 " | head -1)
FS=\$(grep "GNN-SUMMARY" "\$RESULTS_DIR/fitcachepp.log" 2>/dev/null | grep "rank=0 " | head -1)
ncold=\$(echo "\$NS" | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
nwarm=\$(echo "\$NS" | grep -oE 'warm_epoch_wall_mean=[0-9.]+' | cut -d= -f2)
namrt=\$(echo "\$NS" | grep -oE 'amortized_wall=[0-9.]+' | cut -d= -f2)
fcold=\$(echo "\$FS" | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
fwarm=\$(echo "\$FS" | grep -oE 'warm_epoch_wall_mean=[0-9.]+' | cut -d= -f2)
famrt=\$(echo "\$FS" | grep -oE 'amortized_wall=[0-9.]+' | cut -d= -f2)
nck=\$(echo "\$NS" | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
fck=\$(echo "\$FS" | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
trows=\$(echo "\$FS" | grep -oE 'touched_rows=[0-9]+' | cut -d= -f2)
tbytes=\$(echo "\$FS" | grep -oE 'touched_bytes=[0-9]+' | cut -d= -f2)
covt=\$(echo "\$FS" | grep -oE 'coverage_total=[0-9.]+' | cut -d= -f2)
covp=\$(echo "\$FS" | grep -oE 'coverage_paper=[0-9.]+' | cut -d= -f2)
cova=\$(echo "\$FS" | grep -oE 'coverage_author=[0-9.]+' | cut -d= -f2)
fstable=\$(echo "\$FS" | grep -oE 'epoch_cksum_stable=[0-9]+' | cut -d= -f2)
echo "  N=$N_NODES batches=$NUM_BATCHES epochs=$EPOCHS block_bytes=$BLOCK_BYTES"
echo "  touched_rows(rank0)=\$trows touched_bytes(rank0)=\$tbytes"
echo "  coverage total=\$covt paper=\$covp author=\$cova"
echo "  Native_mmap_PFS  cold=\${ncold}s warm=\${nwarm}s amortized=\${namrt}s checksum=\$nck"
echo "  FitCachePP       cold=\${fcold}s warm=\${fwarm}s amortized=\${famrt}s checksum=\$fck (epoch_cksum_stable=\$fstable)"
# Per-rank checksum gate: build sorted "rank<r>=<cksum>" lists from each log and
# require them identical. Comparing only rank-0 scalars would miss a per-rank
# divergence, and head -1 mixes ranks (the original false-FAIL bug).
pairs () { grep "GNN-SUMMARY" "\$1" 2>/dev/null | \\
  sed -nE 's/.*rank=([0-9]+).*GLOBAL_CHECKSUM=([0-9]+).*/\\1=\\2/p' | sort -n; }
NPAIRS=\$(pairs "\$RESULTS_DIR/native.log")
FPAIRS=\$(pairs "\$RESULTS_DIR/fitcachepp.log")
NRANKS=\$(echo "\$NPAIRS" | grep -c '=')
if [ -n "\$NPAIRS" ] && [ "\$NPAIRS" = "\$FPAIRS" ]; then
  echo "  CHECKSUM_GATE: PASS (all \$NRANKS ranks identical Native==FitCachePP)"
else
  echo "  CHECKSUM_GATE: FAIL (per-rank mismatch)"
  echo "    native : \$(echo \$NPAIRS)"
  echo "    fitcppp: \$(echo \$FPAIRS)"
fi
awk -v n="\$nwarm" -v f="\$fwarm" 'BEGIN{ if (f>0) printf "  warm-epoch speedup rank0 (Native/FitCachePP) = %.2fx\n", n/f }'
WH=\$(grep -c "WARM HIT" "\$RESULTS_DIR"/fitcache_intercept_log.*.* 2>/dev/null | awk -F: '{s+=\$NF} END{print s+0}')
echo "  direct-local-mmap WARM HIT log lines (DEBUG-gated): \$WH"
echo "  cache tier: NVMe (/mnt/bb/\$USER, per-node pre-staged feat+CSR); DRAM tier /tmp"
echo "  result path: \$RESULTS_DIR"
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "gnn warm-hit sweep N=$N_NODES job: $JID -> $JOB_DIR"
