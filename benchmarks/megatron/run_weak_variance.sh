#!/bin/bash
# Weak-scaling VARIANCE/DECOMPOSITION follow-up (advisor question: why does
# speedup peak at 256 GPUs then fall?). Per scale, one cold-slot job measures:
#   S1  native cold REPEAT on the scale's own (>=8.5h-cooled) shard range
#       -> slot-to-slot variance of the native side
#   S1b shard->OST stripe map (background) -> offline hot-OST correlation
#   S2  per-node SSD probe (direct-I/O write+read) -> the two SSD classes
#   S3  populate NVMe + warm x3 -> warm stability + straggler repeatability
#   S4  DRAM-tier arm: wipe NVMe cache, repopulate into tmpfs, warm x1
#       -> if the warm tail vanishes, the tail is the slow-SSD class and the
#          tier hierarchy removes it when capacity allows (the "fix")
# usage: run_weak_variance.sh <N_nodes> <shard_base>   (32:960, 256:8128)
set -euo pipefail
N=$1
BASE=$2
REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP
SPN=32
NS=$(( SPN * N ))
SPS=3125
TARGET=$(( SPN * 4 * 1024 * 1024 * 1024 * 95 / 100 ))
TS=$(date +%Y%m%d_%H%M%S)
RD=$REPO/benchmarks/results/frontier/megatron_weak_var/${TS}_N${N}
mkdir -p "$RD"
BEGINLINE=""; [ -n "${FITPP_BEGIN:-}" ] && BEGINLINE="#SBATCH --begin=${FITPP_BEGIN}"
case $N in 256) WT=02:00:00;; *) WT=01:45:00;; esac
cat > "$RD/job.sh" <<EOF
#!/bin/bash
#SBATCH -J mweakvar_N${N}
#SBATCH -t ${WT}
#SBATCH -N ${N}
#SBATCH -C nvme
#SBATCH -p batch
${BEGINLINE}
#SBATCH --account=gen008
#SBATCH -o ${RD}/mvar-%j.out
set -uo pipefail
export FITPP_SITE=frontier FITPP_REPO=${REPO}
cd "\$FITPP_REPO"; source benchmarks/sites/_resolve.sh
RD="${RD}"; cd "\$RD"
RB="\$FITPP_REPO/benchmarks/megatron/megatron_dataloader_bench.py"
CB="\$FITPP_REPO/benchmarks/megatron/llm_coverage_bench.py"
PY="\$FITPP_PYTHON_TORCH"; LIB="\$FITPP_CLIENT_LIB"
DATA="/lustre/orion/gen008/proj-shared/ghu4/data/megatron/synth_weak_16320x4gb"
export BBPATH=/mnt/bb/\$USER FitCache_DATA_DIR="\$DATA"
export FitCache_DRAM_PATH=/tmp/fcpp_var_dram FitCache_NVME_PATH=/mnt/bb/\$USER/fcpp_var_nvme
export FitCache_DRAM_CAPACITY=\$((256*1024*1024)) FitCache_NVME_CAPACITY=\$((1700*1024*1024*1024))
export FitCache_LOG_LEVEL=700 FitCache_PORTS_CFG_DIR="\$RD" FitCache_SERVER_COUNT=${N}
export FitCache_CROSS_JOB=0 FitCache_PREFER_MIGRATE=1 FITCACHE_MMAP_PLACEMENT=node_local
export FitCache_CLUSTER_REGISTRY_DIR="\$RD/registry" FitCache_HEARTBEAT_SEC=120
export FITCACHE_SHARD_BASE=${BASE}
mkdir -p "\$FitCache_DRAM_PATH" "\$FitCache_NVME_PATH" "\$FitCache_CLUSTER_REGISTRY_DIR"
echo "WEAK-VAR N=${N} window=${NS} base=${BASE} (native repeat + warm x3 + DRAM arm)"

echo "=== S1: NATIVE cold REPEAT (8 ranks/node x 4 workers) ==="
( for i in \$(seq ${BASE} \$((BASE+NS-1))); do
    printf 'shard_%04d ' \$i; lfs getstripe -i \$(printf '%s/shard_%04d.bin' "\$DATA" \$i) 2>/dev/null || echo NA
  done > "\$RD/stripe_map.txt" 2>/dev/null ) &
STRIPE_PID=\$!
srun -N ${N} -n \$((8*${N})) --ntasks-per-node=8 --cpus-per-task=7 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_WORLD=${N} FITCACHE_PART_ROTATE=0 FITCACHE_SHARD_BASE=${BASE} \"\$PY\" \"\$RB\" --data-dir \"\$DATA\" --num-shards ${NS} --samples-per-shard ${SPS} --seq-length 1024 --workers 4 --batch-size 16 --label _native2" \\
  2>&1 | tee "\$RD/native2.log" | grep -c 'RAND:'

echo "=== S2: per-node SSD class probe (direct-IO 8 GiB write + read) ==="
srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 bash -c '
  P="\$FitCache_NVME_PATH/probe.bin"
  W=\$( { /usr/bin/time -f "%e" dd if=/dev/zero of="\$P" bs=1M count=8192 oflag=direct conv=fsync 2>/dev/null; } 2>&1 )
  R=\$( { /usr/bin/time -f "%e" dd if="\$P" of=/dev/null bs=1M iflag=direct 2>/dev/null; } 2>&1 )
  rm -f "\$P"
  echo "ssdprobe node=\$SLURM_NODEID host=\$(hostname) write_s=\$W read_s=\$R"' 2>&1 | grep ssdprobe | sort -t= -k2 -n | tee "\$RD/ssd_probe.txt" | head -4

echo "=== S3: servers + populate NVMe + WARM x3 ==="
srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 --cpus-per-task=1 --cpu-bind=cores "\$FITPP_SERVER_BIN" ${N} > "\$RD/server.log" 2>&1 &
SPID=\$!
ND="\$RD/registry/registry.v1/nodes"
for i in \$(seq 1 30); do n=0; [ -d "\$ND" ] && n=\$(grep -h '^server\\..*\\.addr=' "\$ND"/*.txt 2>/dev/null|wc -l); [ "\$n" -ge ${N} ] && break; sleep 1; done
srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_WORLD=${N} FITCACHE_PART_ROTATE=0 FITCACHE_SHARD_BASE=${BASE} FITCACHE_PREFETCH=1 LD_PRELOAD=\"\$LIB\" \"\$PY\" \"\$CB\" --data-dir \"\$DATA\" --num-shards ${NS} --coverage 1.0 --n-chunks 4000 --epochs 1 --seed 0 --label populate" \\
  2>&1 | tee "\$RD/populate.log" | tail -2
for i in \$(seq 1 60); do
  minb=\$(srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 bash -c 'du -sb "\$FitCache_NVME_PATH" 2>/dev/null|cut -f1' 2>/dev/null | sort -n | head -1); minb=\${minb:-0}
  [ "\$minb" -ge ${TARGET} ] && { echo "cached (min_node=\$minb)"; break; }
  sleep 15
done
for w in 1 2 3; do
  srun --overlap -N ${N} -n \$((8*${N})) --ntasks-per-node=8 --cpus-per-task=7 --cpu-bind=cores \\
    bash -c "FITCACHE_PART_WORLD=${N} FITCACHE_PART_ROTATE=0 FITCACHE_SHARD_BASE=${BASE} LD_PRELOAD=\"\$LIB\" \"\$PY\" \"\$RB\" --data-dir \"\$DATA\" --num-shards ${NS} --samples-per-shard ${SPS} --seq-length 1024 --workers 4 --batch-size 16 --label _warm\$w" \\
    2>&1 | tee "\$RD/warm\$w.log" | grep -c 'RAND:'
done
kill -TERM \$SPID 2>/dev/null || true; sleep 3

echo "=== S4: DRAM-tier arm (tmpfs cache; does the warm tail vanish?) ==="
srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 bash -c 'rm -rf "\$FitCache_NVME_PATH"; mkdir -p "\$FitCache_NVME_PATH" "\$FitCache_DRAM_PATH"'
export FitCache_DRAM_CAPACITY=\$((150*1024*1024*1024))
srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 --cpus-per-task=1 --cpu-bind=cores "\$FITPP_SERVER_BIN" ${N} > "\$RD/server_dram.log" 2>&1 &
SPID2=\$!
for i in \$(seq 1 30); do n=0; [ -d "\$ND" ] && n=\$(grep -h '^server\\..*\\.addr=' "\$ND"/*.txt 2>/dev/null|wc -l); [ "\$n" -ge ${N} ] && break; sleep 1; done
srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 --cpus-per-task=8 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_WORLD=${N} FITCACHE_PART_ROTATE=0 FITCACHE_SHARD_BASE=${BASE} FITCACHE_PREFETCH=1 LD_PRELOAD=\"\$LIB\" \"\$PY\" \"\$CB\" --data-dir \"\$DATA\" --num-shards ${NS} --coverage 1.0 --n-chunks 4000 --epochs 1 --seed 0 --label popdram" \\
  2>&1 | tee "\$RD/populate_dram.log" | tail -2
for i in \$(seq 1 60); do
  minb=\$(srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 bash -c 'du -sb "\$FitCache_DRAM_PATH" 2>/dev/null|cut -f1' 2>/dev/null | sort -n | head -1); minb=\${minb:-0}
  [ "\$minb" -ge ${TARGET} ] && { echo "dram-cached (min_node=\$minb)"; break; }
  sleep 15
done
srun --overlap -N ${N} -n \$((8*${N})) --ntasks-per-node=8 --cpus-per-task=7 --cpu-bind=cores \\
  bash -c "FITCACHE_PART_WORLD=${N} FITCACHE_PART_ROTATE=0 FITCACHE_SHARD_BASE=${BASE} LD_PRELOAD=\"\$LIB\" \"\$PY\" \"\$RB\" --data-dir \"\$DATA\" --num-shards ${NS} --samples-per-shard ${SPS} --seq-length 1024 --workers 4 --batch-size 16 --label _warmdram" \\
  2>&1 | tee "\$RD/warm_dram.log" | grep -c 'RAND:'
kill -TERM \$SPID2 2>/dev/null || true; sleep 2
kill \$STRIPE_PID 2>/dev/null || true

echo "============ WEAK-VAR SUMMARY (N=${N}) ============"
for f in native2 warm1 warm2 warm3 warm_dram; do
  awk -v L=\$f '/RAND:/{for(i=1;i<=NF;i++){if(\$i~/^wall=/){sub("wall=","",\$i); v[c++]=\$i+0}}} END{if(c){asort(v); printf "%-10s n=%d min=%.2f p50=%.2f max=%.2f\n",L,c,v[1],v[int(c*0.5)],v[c]}}' "\$RD/\$f.log"
done
echo "--- dram du/node (first 3) ---"
timeout 300 srun --overlap -N ${N} -n ${N} --ntasks-per-node=1 bash -c 'echo node=\$SLURM_NODEID dram=\$(du -sh "\$FitCache_DRAM_PATH" 2>/dev/null|cut -f1) nvme=\$(du -sh "\$FitCache_NVME_PATH" 2>/dev/null|cut -f1)' 2>&1 | sort | head -3
echo "result: \$RD"
EOF
echo "N=${N}: weak-var base=${BASE} window=${NS}  dir=$RD"
bash -n "$RD/job.sh" && sbatch "$RD/job.sh"
