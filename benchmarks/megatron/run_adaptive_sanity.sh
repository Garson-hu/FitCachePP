#!/bin/bash
# Adaptive-placement v1 sanity + overhead (single 2-node debug job).
#   case1 PARTITION_1X : partition hint present  -> prefetch owned slice only
#   case2 REPLICATE_NX : no partition, fits NVMe -> prefetch full set on every node
#   case3 PART_FALLBACK: no partition, tiny budget override -> prefetch nothing
#   case4 overhead     : fitcache_adaptive_decide over 256-file and 16,320-file
#                        corpora (the paper's decision-overhead number)
# Functional verification only; produces no performance table.
set -euo pipefail
REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP
TS=$(date +%Y%m%d_%H%M%S)
RD=$REPO/benchmarks/results/frontier/adaptive_sanity/${TS}_N2
mkdir -p "$RD"
cat > "$RD/job.sh" <<EOF
#!/bin/bash
#SBATCH -J adapt_sanity
#SBATCH -t 00:30:00
#SBATCH -N 2
#SBATCH -C nvme
#SBATCH -p batch
#SBATCH -q debug
#SBATCH --account=gen008
#SBATCH -o ${RD}/adapt-%j.out
set -uo pipefail
export FITPP_SITE=frontier FITPP_REPO=${REPO}
cd "\$FITPP_REPO"; source benchmarks/sites/_resolve.sh
RD="${RD}"; cd "\$RD"
CB="\$FITPP_REPO/benchmarks/megatron/llm_coverage_bench.py"
PY="\$FITPP_PYTHON_TORCH"; LIB="\$FITPP_CLIENT_LIB"
DATA="/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_256x4gb"
export BBPATH=/mnt/bb/\$USER FitCache_DATA_DIR="\$DATA"
export FitCache_DRAM_CAPACITY=\$((256*1024*1024)) FitCache_NVME_CAPACITY=\$((1700*1024*1024*1024))
export FitCache_LOG_LEVEL=700 FitCache_SERVER_COUNT=2
export FitCache_CROSS_JOB=0 FitCache_PREFER_MIGRATE=1 FITCACHE_MMAP_PLACEMENT=node_local
export FitCache_HEARTBEAT_SEC=120

run_case() {  # \$1=name  \$2..=extra env  (uses 8 shards, tiny read)
  local name="\$1"; shift
  local CRD="\$RD/\$name"; mkdir -p "\$CRD/registry"
  export FitCache_DRAM_PATH=/tmp/fcpp_adapt_\${name}_dram
  export FitCache_NVME_PATH=/mnt/bb/\$USER/fcpp_adapt_\${name}_nvme
  export FitCache_PORTS_CFG_DIR="\$CRD" FitCache_CLUSTER_REGISTRY_DIR="\$CRD/registry"
  srun --overlap -N 2 -n 2 --ntasks-per-node=1 bash -c 'mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH"'
  srun --overlap -N 2 -n 2 --ntasks-per-node=1 --cpus-per-task=1 "\$FITPP_SERVER_BIN" 2 > "\$CRD/server.log" 2>&1 &
  local SPID=\$!
  local ND="\$CRD/registry/registry.v1/nodes"
  for i in \$(seq 1 30); do n=0; [ -d "\$ND" ] && n=\$(grep -h '^server\\..*\\.addr=' "\$ND"/*.txt 2>/dev/null|wc -l); [ "\$n" -ge 2 ] && break; sleep 1; done
  echo "=== \$name ==="
  srun --overlap -N 2 -n 2 --ntasks-per-node=1 --cpus-per-task=8 \\
    bash -c "\$* FITCACHE_ADAPTIVE=1 FITCACHE_PREFETCH_WAIT_SEC=180 LD_PRELOAD=\\"\$LIB\\" \\"\$PY\\" \\"\$CB\\" --data-dir \\"\$DATA\\" --num-shards 8 --coverage 0.02 --n-chunks 50 --epochs 1 --seed 0 --label \$name" \\
    2>&1 | tee "\$CRD/bench.log" | grep -aE 'ADAPTIVE|adaptive|partition:' | head -8
  echo "--- \$name du/node ---"
  srun --overlap -N 2 -n 2 --ntasks-per-node=1 bash -c 'echo node=\$SLURM_NODEID \$(du -sh "\$FitCache_NVME_PATH" 2>/dev/null|cut -f1)'
  kill -TERM \$SPID 2>/dev/null || true; sleep 2
  srun --overlap -N 2 -n 2 --ntasks-per-node=1 bash -c 'rm -rf "\$FitCache_NVME_PATH" "\$FitCache_DRAM_PATH"'
}

run_case case1_partition "FITCACHE_PART_WORLD=2"
run_case case2_replicate "FITCACHE_ADAPTIVE_UNPARTITIONABLE=1"
run_case case3_fallback  "FITCACHE_ADAPTIVE_UNPARTITIONABLE=1 FITCACHE_ADAPTIVE_BUDGET=\$((8*1024*1024*1024))"

echo "=== case4 overhead: adaptive_decide scan cost ==="
export FitCache_NVME_PATH=/mnt/bb/\$USER
srun --overlap -N 1 -n 1 bash -c "FITPP_CLIENT_LIB=\\"\$LIB\\" \\"\$PY\\" - <<'PYEOF'
import os, sys, glob
sys.path.insert(0, os.path.join(os.environ['FITPP_REPO'], 'benchmarks'))
from fitcache_prefetch_shim import adaptive_decide
for name, d in [('strong_256f',  '/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_1tb_256x4gb'),
                ('weak_16320f', '/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_weak_16320x4gb')]:
    paths = sorted(glob.glob(os.path.join(d, 'shard_*.bin')))
    for trial in range(3):
        dec = adaptive_decide(paths, None)
        print(f'[overhead] {name} files={len(paths)} trial={trial} '
              f'decide_us={dec[\"decide_us\"]:.1f} mode={dec[\"mode\"]} '
              f'dataset={dec[\"dataset_bytes\"]:,}B budget={dec[\"budget_bytes\"]:,}B', flush=True)
PYEOF"
echo "ADAPTIVE SANITY DONE: \$RD"
EOF
bash -n "$RD/job.sh" && sbatch "$RD/job.sh" && echo "dir=$RD"
