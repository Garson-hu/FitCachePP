#!/bin/bash
# Experiment 2 — Sidecar-Based Cache-State Recovery (generalized harness).
#
# Shows that sidecar metadata restores reusable mmap cache state after the
# FitCachePP metadata service (server set) is killed and restarted, and that
# the restored workload still warm-hits local NVMe through the ORIGINAL PFS
# paths. The sidecar is NOT the source of the mmap bandwidth speedup (that is
# Experiment 1) and does NOT improve every epoch — it restores the cache
# mappings so the Experiment-1 warm-hit performance is preserved across a
# restart and cold metadata recovery is avoided.
#
# Flow (per cell, BENCH x N):
#   P1 populate : server#1 up, bench runs ORGANICALLY (no pre-stage) -> open-time
#                 promotion copies each opened file to node NVMe AND (PERSIST_META=1)
#                 writes a .meta sidecar next to it. Wait for the data mover to
#                 finish (poll until .meta count stabilizes).
#   P2 kill     : kill the server set (metadata service) + wipe ports.cfg so no
#                 stale in-memory state can serve the next phase.
#   P3 restart  : start a fresh server set -> restore_from_sidecars() rebuilds the
#                 server's cache map from the .meta files. Capture restore time +
#                 "total restored = N".
#   P4 post-restart warm pass: bench runs again over the ORIGINAL PFS paths ->
#                 client resolver maps the restored local-NVMe files (warm hit).
#   Resolver probe: for every original path, recompute the deterministic cached
#                 path (tools/fitcache_cached_path) and stat it -> cache-hit vs
#                 fallback counts (deterministic; matches the client resolver).
#
# Usage: BENCH=megatron|gnn|dinov2 N_NODES=1 QOS=debug bash scripts/frontier/frontier_sidecar_recovery.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

BENCH="${BENCH:?set BENCH=megatron|gnn|dinov2}"
N_NODES="${N_NODES:-1}"
QOS="${QOS:-debug}"
PARTITION="${PARTITION:-$FITPP_SLURM_PARTITION}"
WALLTIME="${WALLTIME:-01:55:00}"
SERVERS_PER_NODE="${SERVERS_PER_NODE:-4}"
TOTAL_SERVERS=$((N_NODES * SERVERS_PER_NODE))
RESTART_WAIT="${RESTART_WAIT:-25}"
PROMOTE_WAIT_MAX="${PROMOTE_WAIT_MAX:-1200}"   # max seconds to wait for promotion+sidecars
SKIP_POST="${SKIP_POST:-0}"   # 1 = Experiment 4 restore-scaling: measure restore only, skip the post-restart data pass
PERSIST_META="${PERSIST_META:-1}"   # 1 = with sidecar (write+restore); 0 = no sidecar (Experiment 3 ablation no-sidecar arm)
ARM_TAG="${ARM_TAG:-}"        # optional label suffix for the run dir (e.g. with_sidecar / no_sidecar)
PLACEMENT="${PLACEMENT:-hash}"   # Experiment 5: hash (default, scatter) | node_local (route mmap promotion to a local server)

# Per-benchmark config: data dir, expected cached-object count/node, Exp-1 warm-hit
# reference (s, N=1), and the bench command template (FITPP_CLIENT_LIB preload always).
case "$BENCH" in
  megatron)
    DATA_DIR="${DATA_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_64x16gb}"
    NUM_SHARDS="${NUM_SHARDS:-40}"
    BENCH_PY="benchmarks/megatron/llm_coverage_bench.py"
    BENCH_ARGS="--data-dir $DATA_DIR --num-shards $NUM_SHARDS --coverage 1.0 --n-chunks 4000"
    EXP1_WARM="271.9"   # N=1 Experiment-1 warm-hit epoch (s)
    EXP_OBJECTS=$NUM_SHARDS; PROBE_N=$NUM_SHARDS ;;
  gnn)
    DATA_DIR="${DATA_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/gnn/igb_large_real}"
    NUM_BATCHES="${NUM_BATCHES:-30}"
    BENCH_PY="benchmarks/gnn/gnn_feature_bench.py"
    BENCH_ARGS="--data-dir $DATA_DIR --num-batches $NUM_BATCHES"
    EXP1_WARM="18.6"
    EXP_OBJECTS=6; PROBE_N=0 ;;   # paper_feat, author_feat, 2x csr_indptr, 2x csr_indices
  dinov2)
    DATA_DIR="${DATA_DIR:-/lustre/orion/gen008/proj-shared/ghu4/data/dinov2/cc12m_wds}"
    NUM_SHARDS="${NUM_SHARDS:-996}"
    BENCH_PY="benchmarks/dinov2/cc12m_mmap_bench.py"
    # DINO_SHARD_MODE=shared (default): every rank reads the same NUM_SHARDS shards (--shared).
    # DINO_SHARD_MODE=partitioned: drop --shared so the bench's disjoint mode assigns
    # rank r the shards [r*NUM_SHARDS,(r+1)*NUM_SHARDS) -> with 1 rank/node, each NODE
    # caches only its own NUM_SHARDS shards (Experiment 5b partitioned access; pass
    # NUM_SHARDS = total/N, e.g. 498 for 996 shards at N=2). EXP_OBJECTS/PROBE_N then
    # refer to the per-node assigned count.
    DINO_SHARD_MODE="${DINO_SHARD_MODE:-shared}"
    SHARED_ARG="--shared"; [ "$DINO_SHARD_MODE" = "partitioned" ] && SHARED_ARG=""
    BENCH_ARGS="--data-dir $DATA_DIR --num-shards $NUM_SHARDS $SHARED_ARG --decode-every 500"
    EXP1_WARM="233.3"
    EXP_OBJECTS=$NUM_SHARDS; PROBE_N=$NUM_SHARDS ;;
  *) echo "unknown BENCH=$BENCH"; exit 2 ;;
esac

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_sidecar_recovery_${BENCH}_N${N_NODES}${ARM_TAG:+_$ARM_TAG}
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/sidecar_recovery/${RUN_TAG}"
mkdir -p "$JOB_DIR"
QOS_LINE=""; [ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J sc_rec_${BENCH}_N${N_NODES}
#SBATCH -t $WALLTIME
#SBATCH -N $N_NODES
#SBATCH -C nvme
#SBATCH -p $PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/sc_rec-%j.out
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
set -uo pipefail
cd \$FITPP_REPO
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh
RESULTS_DIR="$JOB_DIR"; cd "\$RESULTS_DIR"
PY="\$FITPP_PYTHON_TORCH"
BENCH_PY="\$FITPP_REPO/$BENCH_PY"
TOOL="\$FITPP_REPO/tools/fitcache_cached_path"

export BBPATH=/mnt/bb/\$USER
export FitCache_DATA_DIR="$DATA_DIR"
export FitCache_DRAM_PATH=/tmp/fitcachepp_screc_dram
export FitCache_NVME_PATH=/mnt/bb/\$USER/fitcachepp_screc_nvme
export FitCache_DRAM_CAPACITY=\$((256 * 1024 * 1024))      # tiny -> everything resolves on NVMe tier
export FitCache_NVME_CAPACITY=\$((3000 * 1024 * 1024 * 1024))
export FitCache_LOG_LEVEL=600
export FitCache_PORTS_CFG_DIR="\$RESULTS_DIR"
export FitCache_SERVER_COUNT=$TOTAL_SERVERS
export FitCache_CROSS_JOB=0
export FitCache_PERSIST_META=$PERSIST_META   # 1=write+restore sidecars; 0=no sidecar (ablation)
export SKIP_POST=$SKIP_POST
export FITCACHE_MMAP_PLACEMENT=$PLACEMENT     # Experiment 5: hash | node_local
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"

metacount () { find "\$FitCache_NVME_PATH" "\$FitCache_DRAM_PATH" -name '*.meta' 2>/dev/null | wc -l; }
cachedcount () { find "\$FitCache_NVME_PATH" "\$FitCache_DRAM_PATH" -type f -not -name '*.meta' -not -name '*.broken' 2>/dev/null | wc -l; }
metabytes () { find "\$FitCache_NVME_PATH" "\$FitCache_DRAM_PATH" -name '*.meta' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'; }

run_bench () { # label logf preload(0|1) extra_args
  if [ "\$3" = "1" ]; then PRE="LD_PRELOAD=\"\$FITPP_CLIENT_LIB\""; else PRE=""; fi
  srun -N $N_NODES -n $N_NODES --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores bash -c \\
    "\$PRE \"\$PY\" \"\$BENCH_PY\" $BENCH_ARGS \$4 --label \"\$1\"" 2>&1 | tee "\$RESULTS_DIR/\$2"
}

echo "==== P1: populate (server#1 + organic bench, open-time promotion + sidecars) ===="
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS > "\$RESULTS_DIR/server1.log" 2>&1 &
S1=\$!
sleep 15
run_bench "populate" "populate.log" 1 "--epochs 2"   # equal epochs in both phases so raw GLOBAL_CHECKSUM is directly comparable (benches differ: megatron sums over epochs, cc12m reports per-epoch)
echo "[P1] waiting for data mover to finish copying + writing sidecars (max ${PROMOTE_WAIT_MAX}s)..."
WSTART=\$SECONDS; PREV=-1
while [ \$((SECONDS-WSTART)) -lt $PROMOTE_WAIT_MAX ]; do
  NM=\$(metacount)
  if [ "\$NM" -ge "$EXP_OBJECTS" ]; then break; fi
  if [ "\$NM" = "\$PREV" ]; then sleep 20; NM2=\$(metacount); [ "\$NM2" = "\$NM" ] && break; fi
  PREV=\$NM; sleep 15
done
NMETA1=\$(metacount); NCACHED1=\$(cachedcount); MBYTES=\$(metabytes)
echo "[P1] sidecars=\$NMETA1 cached_objects=\$NCACHED1 sidecar_meta_bytes=\$MBYTES (expected ~$EXP_OBJECTS)"

echo "==== P2: kill metadata service (server#1) + wipe ports.cfg ===="
kill -TERM \$S1 2>/dev/null || true
sleep $RESTART_WAIT
pkill -f "\$FITPP_SERVER_BIN" 2>/dev/null || true
sleep 5
rm -f "\$RESULTS_DIR"/.ports.cfg.* 2>/dev/null || true
echo "[P2] server killed; ports.cfg wiped; in-memory map gone"

echo "==== P3: restart server#2 -> restore_from_sidecars ===="
RESTART_T0=\$SECONDS
srun -N $N_NODES -n $TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE --cpus-per-task=1 --cpu-bind=cores \\
     "\$FITPP_SERVER_BIN" $TOTAL_SERVERS > "\$RESULTS_DIR/server2.log" 2>&1 &
S2=\$!
# Wait for server#2's NON-ZERO restore. (server#1 logged "total restored = 0" at
# its own empty-cache startup; we must not sample that stale line — wait until a
# >=1 restore appears, then take the max across all server logs = server#2's count.)
RSTART=\$SECONDS
while [ \$((SECONDS-RSTART)) -lt 120 ]; do
  MAXR=\$(grep -hoE "total restored = [0-9]+" "\$RESULTS_DIR"/fitcache_server_log.*.* 2>/dev/null | grep -oE "[0-9]+" | sort -rn | head -1)
  [ "\${MAXR:-0}" -ge 1 ] && break
  sleep 2
done
sleep 3
RESTORED=\$(grep -hoE "total restored = [0-9]+" "\$RESULTS_DIR"/fitcache_server_log.*.* 2>/dev/null | grep -oE "[0-9]+" | sort -rn | head -1)
RESTORE_WALL=\$((SECONDS - RESTART_T0))
echo "[P3] restored=\${RESTORED:-0} restore_wall=\${RESTORE_WALL}s"

if [ "\$SKIP_POST" = "1" ]; then
  echo "==== P4 SKIPPED (SKIP_POST=1: restore-scaling, metadata-restore-only) ===="
  HIT=na; FB=na
else
echo "==== P4: post-restart passes (2 epochs: pass1 cold-from-NVMe, pass2 page-cached warm) ===="
# 2 epochs so we can report pass 1 (first pass after sidecar restore = cold-from-NVMe)
# AND pass 2 (page-cached warm). For GNN (working set < RAM) pass 2 is the apples-to-
# apples comparison vs the page-cache-affected Experiment-1 warm-hit; for Megatron/DINOv2
# (working set > RAM) pass 1 ~= pass 2.
run_bench "post_restart" "post_restart.log" 1 "--epochs 2"
fi
kill -TERM \$S2 2>/dev/null || true; sleep 3

echo "==== Resolver probe: deterministic cache-hit vs fallback over original paths ===="
# Replays the client resolver: for each original file, the cached path must exist
# on NVMe with matching size to warm-hit; otherwise the client falls back.
PROBE=\$("\$PY" - "$BENCH" "$DATA_DIR" "$PROBE_N" <<'PYEOF'
import os,sys,subprocess
bench,dd=sys.argv[1],sys.argv[2]
nvme=os.environ["FitCache_NVME_PATH"]; tool=os.path.join(os.environ["FITPP_REPO"],"tools/fitcache_cached_path")
files=[]
if bench=="megatron":
    n=int(sys.argv[3]); files=[os.path.join(dd,f"shard_{i:04d}.bin") for i in range(n)]
elif bench=="gnn":
    files=[os.path.join(dd,x) for x in ["paper_node_feat.npy","author_node_feat.npy",
        "paper_cites_paper.csr_indptr.npy","paper_cites_paper.csr_indices.npy",
        "paper_written_by_author.csr_indptr.npy","paper_written_by_author.csr_indices.npy"]]
elif bench=="dinov2":
    n=int(sys.argv[3]); files=[os.path.join(dd,f"cc12m-train-{i:04d}.tar") for i in range(n)]
hit=fb=0
for f in files:
    if not os.path.exists(f): continue
    dst=subprocess.check_output([tool,f,nvme]).decode().strip()
    try:
        if os.path.exists(dst) and os.path.getsize(dst)==os.path.getsize(f): hit+=1
        else: fb+=1
    except OSError: fb+=1
print(f"{hit} {fb}")
PYEOF
)
HIT=\$(echo "\$PROBE" | awk '{print \$1}'); FB=\$(echo "\$PROBE" | awk '{print \$2}')

echo ""
echo "==================== SIDECAR RECOVERY SUMMARY ($BENCH N=$N_NODES) ===================="
gw () { grep -h "SUMMARY" "\$1" 2>/dev/null | head -1; }   # matches SUMMARY / GNN-SUMMARY / CC12M-SUMMARY
PW=\$(gw "\$RESULTS_DIR/populate.log");  AW=\$(gw "\$RESULTS_DIR/post_restart.log")
pwall=\$(echo "\$PW" | grep -oE '(cold_epoch_wall|amortized_wall)=[0-9.]+' | head -1 | cut -d= -f2)
# post-restart pass 1 = cold_epoch_wall (first pass after restore, cold-from-NVMe);
# pass 2 = warm_epoch_wall_mean (page-cached). GNN compares pass 2 vs Exp-1 warm.
p1=\$(echo "\$AW" | grep -oE 'cold_epoch_wall=[0-9.]+' | head -1 | cut -d= -f2)
p2=\$(echo "\$AW" | grep -oE 'warm_epoch_wall_mean=[0-9.]+' | head -1 | cut -d= -f2)
# Both phases run --epochs 2, so raw GLOBAL_CHECKSUM is directly comparable regardless of
# whether a bench sums over epochs (megatron) or reports per-epoch (cc12m/gnn).
pck=\$(echo "\$PW" | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
ack=\$(echo "\$AW" | grep -oE 'GLOBAL_CHECKSUM=[0-9]+' | cut -d= -f2)
dec=\$(echo "\$AW" | grep -oE 'decode_ok=[0-9]+' | cut -d= -f2)
echo "  benchmark=$BENCH  N=$N_NODES  dataset_dir=$DATA_DIR"
echo "  cached_objects=\$NCACHED1  sidecar_entries=\$NMETA1  sidecar_meta_bytes=\$MBYTES"
echo "  persist_meta(with_sidecar)=$PERSIST_META   restore_time=\${RESTORE_WALL}s  restored_entries=\${RESTORED:-0}  expected=$EXP_OBJECTS  missing=\$(( $EXP_OBJECTS - \${RESTORED:-0} ))"
awk -v r="\${RESTORED:-0}" -v t="\${RESTORE_WALL:-0}" 'BEGIN{ if(t>0) printf "  entries_restored_per_sec = %.1f\n", r/t; else printf "  entries_restored_per_sec = %s (restore <1s)\n", r }'
echo "  cache_hit_count=\$HIT  fallback_count=\$FB  (deterministic resolver probe)"
if [ "\$SKIP_POST" = "1" ]; then
  echo "  (SKIP_POST=1: restore-scaling run, post-restart data pass skipped)"
else
  echo "  post_restart_pass1 (cold-from-NVMe) =\${p1}s"
  echo "  post_restart_pass2 (page-cached warm)=\${p2}s   Experiment-1 warm-hit (ref, N=1)=${EXP1_WARM}s"
  awk -v a="\$p2" -v e="$EXP1_WARM" 'BEGIN{ if(a>0&&e>0) printf "  perf_delta_pass2_vs_exp1_warm = %+.1f%%\n", 100*(a-e)/e }'
  echo "  populate_pass=\${pwall}s (organic cold-from-Lustre/promote)  checksum populate=\$pck post_restart=\$ack  decode_ok=\${dec:-n/a}"
  if [ "\$pck" = "\$ack" ] && [ -n "\$ack" ] && [ "\$ack" != "0" ]; then echo "  CHECKSUM_GATE: PASS"; else echo "  CHECKSUM_GATE: FAIL (\$pck / \$ack)"; fi
fi
if [ "\${RESTORED:-0}" -ge "$EXP_OBJECTS" ]; then echo "  RESTORE_GATE: PASS (restored \${RESTORED:-0} >= expected $EXP_OBJECTS, missing 0)"; else echo "  RESTORE_GATE: CHECK (restored=\${RESTORED:-0}/$EXP_OBJECTS)"; fi
[ "\$SKIP_POST" != "1" ] && { if [ "\${RESTORED:-0}" -ge "$EXP_OBJECTS" ] && [ "\$FB" = "0" ]; then echo "  RECOVERY_GATE: PASS (restored>=expected, fallback=0)"; else echo "  RECOVERY_GATE: CHECK (restored=\${RESTORED:-0}/$EXP_OBJECTS, fallback=\$FB)"; fi; }
echo "  result path: \$RESULTS_DIR"
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "sidecar-recovery $BENCH N=$N_NODES job: $JID -> $JOB_DIR"
