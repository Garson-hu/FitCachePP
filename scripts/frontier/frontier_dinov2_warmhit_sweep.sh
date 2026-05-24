#!/bin/bash
# DINOv2 / CC12M-wds vision mmap benchmark: warm-hit DIRECT LOCAL-NVMe mmap of
# WebDataset tar shards. FitCachePP (warm-hit direct mmap of pre-staged cached
# shard) vs Native_mmap_PFS (plain numpy.memmap of the PFS shard).
#
# NOT full DINOv2 training: no model/SSL loss. Claim limited to mmap-backed
# vision DATA LOADING. Touch = np.sum over every jpg byte range (checksum gate);
# decode-success on a 1-in-DECODE_EVERY subset = correctness signal (subset so
# libjpeg CPU does not mask the mmap I/O being measured).
#
# Each node (rank) processes a DISJOINT shard range [r*NUM_SHARDS,(r+1)*NUM_SHARDS)
# and pre-stages exactly its shards to node-local NVMe at the resolver hash-bin
# path -> guaranteed warm hit, no cross-node Lustre OST-cache sharing. Pre-stage
# cost reported separately (NOT a cold epoch). Per-rank checksum-equality HARD gate.
#
# Usage: N_NODES=1 NUM_SHARDS=8 QOS=develop PARTITION=service bash scripts/frontier/frontier_dinov2_warmhit_sweep.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_NODES="${N_NODES:-1}"
NUM_SHARDS="${NUM_SHARDS:-8}"
# SHARED=1: every node stages + every rank reads the SAME [0,NUM_SHARDS) shards
# (shared full-corpus mode). Default 0 = disjoint per-rank ranges.
SHARED="${SHARED:-0}"
if [ "$SHARED" = "1" ]; then SHARED_FLAG="--shared"; STAGE_MODE="shared full-corpus"; else SHARED_FLAG=""; STAGE_MODE="disjoint/node"; fi
EPOCHS="${EPOCHS:-2}"
DECODE_EVERY="${DECODE_EVERY:-50}"
QOS="${QOS:-debug}"
PARTITION="${PARTITION:-$FITPP_SLURM_PARTITION}"
WALLTIME="${WALLTIME:-01:15:00}"
DATA_DIR="${DATA_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/dinov2/cc12m_wds}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_dinov2_warmhit_N${N_NODES}
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/dinov2_warmhit_sweep/${RUN_TAG}"
mkdir -p "$JOB_DIR"
QOS_LINE=""; [ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J dino_wh_N${N_NODES}
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/dino_wh-%j.out
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
set -uo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh
RESULTS_DIR="$JOB_DIR"; cd "\$RESULTS_DIR"
BENCH="\$FITPP_REPO/benchmarks/dinov2/cc12m_mmap_bench.py"
PY="\$FITPP_PYTHON_TORCH"

export BBPATH=/mnt/bb/\$USER
export FitCache_DATA_DIR="$DATA_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_dino_dram
export FitCache_NVME_PATH=/mnt/bb/\$USER/fitcachepp_dino_nvme
export FitCache_DRAM_CAPACITY=\$((256 * 1024 * 1024))
export FitCache_NVME_CAPACITY=\$((2000 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$TOTAL_SERVERS
export FitCache_CROSS_JOB=0
export SHARED=$SHARED

# Pre-stage: SHARED=1 -> every node stages the SAME [0,NUM_SHARDS) shards (full
# corpus on every node); else node r stages disjoint [r*NUM_SHARDS,(r+1)*NUM_SHARDS).
echo "=== PRE-STAGE on all $N_NODES nodes ($STAGE_MODE, $NUM_SHARDS shards) ==="
STAGE_START=\$SECONDS
srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpu-bind=cores bash -c '
  mkdir -p "\$FitCache_NVME_PATH"
  if [ "\$SHARED" = "1" ]; then base=0; else base=\$(( SLURM_PROCID * '"$NUM_SHARDS"' )); fi
  for i in \$(seq \$base \$(( base + $NUM_SHARDS - 1 ))); do
    f=\$(printf "$DATA_DIR/cc12m-train-%04d.tar" \$i)
    [ -f "\$f" ] || continue
    dst=\$("\$FITPP_REPO/tools/fitcache_cached_path" "\$f" "\$FitCache_NVME_PATH")
    mkdir -p "\$(dirname "\$dst")"
    if [ ! -f "\$dst" ] || [ "\$(stat -c %s "\$dst" 2>/dev/null || echo 0)" != "\$(stat -c %s "\$f")" ]; then
      cp "\$f" "\$dst"
    fi
  done
  echo "[stage] \$(hostname) procid \$SLURM_PROCID: shards \$base..\$((base+$NUM_SHARDS-1)), \$(du -sb "\$FitCache_NVME_PATH" | cut -f1) bytes"
'
echo "stage wall=\$((SECONDS - STAGE_START))s"

mkdir -p "\$FitCache_DRAM_PATH"
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS > "\$RESULTS_DIR/server.log" 2>&1 &
SPID=\$!
sleep 15

run () { # label preload logf
  echo "=== \$1 (N=$N_NODES, $NUM_SHARDS shards/node, $EPOCHS ep) ==="
  if [ -n "\$2" ]; then
    srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \\
      "LD_PRELOAD=\"\$2\" \"\$PY\" \"\$BENCH\" --data-dir \"$DATA_DIR\" --num-shards $NUM_SHARDS --epochs $EPOCHS --decode-every $DECODE_EVERY $SHARED_FLAG --label \"\$1\"" \\
      2>&1 | tee "\$RESULTS_DIR/\$3"
  else
    srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \\
      "\"\$PY\" \"\$BENCH\" --data-dir \"$DATA_DIR\" --num-shards $NUM_SHARDS --epochs $EPOCHS --decode-every $DECODE_EVERY $SHARED_FLAG --label \"\$1\"" \\
      2>&1 | tee "\$RESULTS_DIR/\$3"
  fi
}

run "Native_mmap_PFS"  ""                   "native.log"
run "FitCachePP"       "\$FITPP_CLIENT_LIB"  "fitcachepp.log"

kill -TERM \$SPID 2>/dev/null || true; sleep 3

echo ""
echo "==================== DINOV2 CC12M WARM-HIT SWEEP SUMMARY (N=$N_NODES) ===================="
NS=\$(grep "CC12M-SUMMARY" "\$RESULTS_DIR/native.log" 2>/dev/null | grep "rank=0 " | head -1)
FS=\$(grep "CC12M-SUMMARY" "\$RESULTS_DIR/fitcachepp.log" 2>/dev/null | grep "rank=0 " | head -1)
ncold=\$(echo "\$NS" | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
nwarm=\$(echo "\$NS" | grep -oE 'warm_epoch_wall_mean=[0-9.]+' | cut -d= -f2)
namrt=\$(echo "\$NS" | grep -oE 'amortized_wall=[0-9.]+' | cut -d= -f2)
fcold=\$(echo "\$FS" | grep -oE 'cold_epoch_wall=[0-9.]+' | cut -d= -f2)
fwarm=\$(echo "\$FS" | grep -oE 'warm_epoch_wall_mean=[0-9.]+' | cut -d= -f2)
famrt=\$(echo "\$FS" | grep -oE 'amortized_wall=[0-9.]+' | cut -d= -f2)
jpgs=\$(echo "\$FS" | grep -oE 'jpgs=[0-9]+' | cut -d= -f2)
tb=\$(echo "\$FS" | grep -oE 'touched_bytes=[0-9]+' | cut -d= -f2)
dec=\$(echo "\$FS" | grep -oE 'decoded=[0-9]+' | head -1 | cut -d= -f2)
deck=\$(echo "\$FS" | grep -oE 'decode_ok=[0-9]+' | cut -d= -f2)
echo "  N=$N_NODES shards/node=$NUM_SHARDS epochs=$EPOCHS decode_every=$DECODE_EVERY"
echo "  jpgs(rank0)=\$jpgs touched_bytes(rank0)=\$tb decoded=\$dec decode_ok=\$deck"
echo "  --- View 1: warm-hit-only (mechanism) ---"
echo "  Native_mmap_PFS  cold=\${ncold}s warm=\${nwarm}s"
echo "  FitCachePP       cold=\${fcold}s warm=\${fwarm}s"
awk -v n="\$nwarm" -v f="\$fwarm" 'BEGIN{ if (f>0) printf "  warm-hit speedup (Native/FitCachePP) = %.2fx\n", n/f }'
echo "  --- View 2: end-to-end amortized incl pre-stage=\${STAGE_WALL:-see above} ---"
SW=\$(grep -oE 'stage wall=[0-9]+' "\$RESULTS_DIR"/dino_wh-*.out 2>/dev/null | head -1 | grep -oE '[0-9]+')
awk -v sw="\$SW" -v n="\$nwarm" -v f="\$fwarm" 'BEGIN{
  if (f>0 && n>0) {
    be="n/a"; for (e=1;e<=5;e++){ if (sw + f*e < n*e){ be=e; break } }
    printf "  pre-stage=%ss  break-even epoch=%s\n", sw, be
    for (e=1;e<=5;e++) printf "    @%dep: FCP=%.0fs Native=%.0fs amort_speedup=%.2fx\n", e, sw+f*e, n*e, (n*e)/(sw+f*e)
  }
}'
# Per-rank checksum-equality gate.
pairs () { grep "CC12M-SUMMARY" "\$1" 2>/dev/null | sed -nE 's/.*rank=([0-9]+).*GLOBAL_CHECKSUM=([0-9]+).*/\\1=\\2/p' | sort -n; }
NP=\$(pairs "\$RESULTS_DIR/native.log"); FP=\$(pairs "\$RESULTS_DIR/fitcachepp.log")
NR=\$(echo "\$NP" | grep -c '=')
if [ -n "\$NP" ] && [ "\$NP" = "\$FP" ]; then echo "  CHECKSUM_GATE: PASS (all \$NR ranks identical Native==FitCachePP)";
else echo "  CHECKSUM_GATE: FAIL"; echo "    native : \$(echo \$NP)"; echo "    fitcppp: \$(echo \$FP)"; fi
echo "  cache tier: NVMe (/mnt/bb/\$USER, per-node disjoint pre-staged tar shards)"
echo "  result path: \$RESULTS_DIR"
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "dinov2 cc12m warm-hit sweep N=$N_NODES job: $JID -> $JOB_DIR"
