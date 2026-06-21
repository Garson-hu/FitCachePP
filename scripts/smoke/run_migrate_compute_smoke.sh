#!/bin/bash
#
# run_migrate_compute_smoke.sh
#
# Validate the peer->local MIGRATION primitive (TPDS) on a real Frontier compute
# node, over real Mercury bulk, in ISOLATION from the prefetch client + routing.
# Two cross-job servers run on ONE node (distinct NVMe tiers, shared registry);
# server S2 carries FitCache_MIGRATE_SELFTEST=<file_0> so its self-test thread
# pulls file_0 peer->local from S1 once S1 announces it. No multi-node coupling,
# no client prefetch routing — just: does the migrate RPC + bulk + landing work.
#
# Submits a short 1-node job. On success the job log prints
# "PASS: file_0 migrated S1->S2 ... sha256 match".
#
# Usage: bash scripts/frontier/.. ; QOS=debug PARTITION=batch bash scripts/smoke/run_migrate_compute_smoke.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export FITPP_SITE=frontier
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

QOS="${QOS:-debug}"
PARTITION="${PARTITION:-$FITPP_SLURM_PARTITION}"
WALLTIME="${WALLTIME:-00:20:00}"
RUN_TAG=$(date +'%Y%m%d_%H%M%S')_migrate_smoke
JOB_DIR="$FITPP_REPO/benchmarks/results/frontier/migrate_smoke/${RUN_TAG}"
mkdir -p "$JOB_DIR"
QOS_LINE=""; [ -n "$QOS" ] && QOS_LINE="#SBATCH -q $QOS"

cat > "$JOB_DIR/job.sh" <<EOF
#!/bin/bash
#SBATCH -J migrate_smoke
#SBATCH -t $WALLTIME
#SBATCH -N 1
#SBATCH -C nvme
#SBATCH -p $PARTITION
#SBATCH --account=$FITPP_SLURM_ACCOUNT
${QOS_LINE}
#SBATCH -o $JOB_DIR/migrate_smoke-%j.out
set -uo pipefail
export FITPP_SITE=frontier
export FITPP_REPO=$FITPP_REPO
cd "\$FITPP_REPO"
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

SERVER_BIN="\$FITPP_SERVER_BIN"
CLIENT_LIB="\$FITPP_CLIENT_LIB"
HARNESS_BIN="\$FITPP_REPO/build/tests/harness_read_files"
CACHED_PATH="\$FITPP_REPO/tools/fitcache_cached_path"

SR="$JOB_DIR/work"
mkdir -p "\$SR"/{dataset,registry,logs,cwd}
BB=/mnt/bb/\$USER
mkdir -p "\$BB/mig_c1" "\$BB/mig_c2"

# Dataset on Lustre (PFS) so both servers' processes can stat the original.
head -c \$((10 * 1024 * 1024)) /dev/urandom > "\$SR/dataset/file_0.bin"
for i in 1 2 3; do head -c \$((256 * 1024)) /dev/urandom > "\$SR/dataset/file_\$i.bin"; done
SRC_FILE="\$SR/dataset/file_0.bin"
SRC_SUM=\$(sha256sum "\$SRC_FILE" | cut -d' ' -f1)
echo "dataset file_0=10MiB sha256=\${SRC_SUM:0:16}"

export FitCache_DATA_DIR="\$SR/dataset"
export FitCache_CROSS_JOB=1
export FitCache_PREFER_MIGRATE=1
export FitCache_CLUSTER_REGISTRY_DIR="\$SR/registry"
export FitCache_HEARTBEAT_SEC=3
export FitCache_LOG_LEVEL=700
export FitCache_SERVER_COUNT=1
# node_local routing: each client routes to its OWN job's server (slot 0)
# deterministically, instead of HRW-scattering caches across the cluster
# (which broke the "S1 owns the source" assumption). Matches the experiment.
export FITCACHE_MMAP_PLACEMENT=node_local
cd "\$SR/cwd"

start_server() { # jobid procid nvme log selftest
  SLURM_JOBID=\$1 SLURM_PROCID=\$2 \\
  FitCache_DRAM_PATH="\$SR/dram_\$2" FitCache_NVME_PATH="\$3" \\
  FitCache_DRAM_CAPACITY=\$((64*1024*1024)) FitCache_NVME_CAPACITY=\$((2*1024*1024*1024)) \\
  FitCache_MIGRATE_SELFTEST="\${5:-}" \\
  "\$SERVER_BIN" 2 > "\$4" 2>&1 &
  echo \$!
}

echo "=== start S1 (jobid 1001) + S2 (jobid 1002, selftest=file_0) on this node ==="
S1=\$(start_server 1001 0 "\$BB/mig_c1" "\$SR/logs/s1.log" "")
S2=\$(start_server 1002 1 "\$BB/mig_c2" "\$SR/logs/s2.log" "\$SRC_FILE")
echo "S1=\$S1 S2=\$S2"
trap 'kill -TERM \$S1 \$S2 2>/dev/null; sleep 1; kill -9 \$S1 \$S2 2>/dev/null' EXIT

# wait registry 2 live
ND="\$SR/registry/registry.v1/nodes"
for i in \$(seq 1 25); do
  n=0; [ -d "\$ND" ] && n=\$(grep -h '^server\..*\.addr=' "\$ND"/*.txt 2>/dev/null | wc -l)
  [ "\$n" -ge 2 ] && { echo "registry: \$n live after \${i}s"; break; }
  sleep 1
done

echo "=== client A (jobid 1001): read dataset via S1 -> cache + broadcast ==="
SLURM_JOBID=1001 SLURM_PROCID=0 \\
  FitCache_DRAM_PATH="\$SR/dram_0" FitCache_NVME_PATH="\$BB/mig_c1" \\
  FitCache_DRAM_CAPACITY=\$((64*1024*1024)) FitCache_NVME_CAPACITY=\$((2*1024*1024*1024)) \\
  LD_PRELOAD="\$CLIENT_LIB" "\$HARNESS_BIN" "\$SR/dataset" > "\$SR/logs/client_a.log" 2>&1 || \\
  { echo "client A failed"; tail -20 "\$SR/logs/client_a.log"; }

DST=\$("\$CACHED_PATH" "\$SRC_FILE" "\$BB/mig_c2")
echo "expect migrated copy: \$DST"
OK=0
for i in \$(seq 1 70); do
  if [ -f "\$DST" ] && [ "\$(stat -c %s "\$DST" 2>/dev/null||echo 0)" = "\$(stat -c %s "\$SRC_FILE")" ]; then OK=1; echo "migrated after \${i}s"; break; fi
  sleep 1
done

echo "=== S2 migration trace ==="; grep -aE "MIGRATE_SELFTEST|migrate:|migrate serve|migrate pull" "\$SR"/cwd/fitcache_server_log.\$S2.* 2>/dev/null | tail -20 || true
echo "=== S1 promote/broadcast trace ==="; grep -aE "Caching|Copied|broadcast|register_file" "\$SR"/cwd/fitcache_server_log.\$S1.* 2>/dev/null | tail -15 || true

if [ "\$OK" = "1" ]; then
  DST_SUM=\$(sha256sum "\$DST" | cut -d' ' -f1)
  if [ "\$DST_SUM" = "\$SRC_SUM" ]; then echo "PASS: file_0 migrated S1->S2 over Mercury bulk; sha256 match (\$(stat -c %s "\$DST") bytes)";
  else echo "FAIL: content mismatch src=\${SRC_SUM:0:16} dst=\${DST_SUM:0:16}"; fi
else
  echo "FAIL: migrated copy absent at \$DST"
  echo "--- s2.log tail ---"; tail -25 "\$SR/logs/s2.log" 2>/dev/null
  echo "--- fitcache_server_log S2 tail ---"; tail -30 "\$SR"/cwd/fitcache_server_log.\$S2.* 2>/dev/null
fi
echo
echo "=== client-prefetch path: jobid 1002 prefetch(file_1) via shim -> S2 migrate ==="
FILE1="\$SR/dataset/file_1.bin"
SLURM_JOBID=1002 SLURM_PROCID=1 \\
  FitCache_DRAM_PATH="\$SR/dram_1" FitCache_NVME_PATH="\$BB/mig_c2" \\
  FitCache_DRAM_CAPACITY=\$((64*1024*1024)) FitCache_NVME_CAPACITY=\$((2*1024*1024*1024)) \\
  LD_PRELOAD="\$CLIENT_LIB" python3 -c "
import sys; sys.path.insert(0,'\$FITPP_REPO/benchmarks')
import fitcache_prefetch_shim as s
print('[pf] available=', s.available(), 'prefetch_ret=', s.prefetch('\$FILE1', s.REPL_SINGLE_COPY), 'landed=', s.wait_local(['\$FILE1'], 60), flush=True)
" 2>&1 | tail -5 || true
DST1=\$("\$CACHED_PATH" "\$FILE1" "\$BB/mig_c2")
if [ -f "\$DST1" ] && [ "\$(stat -c %s "\$DST1" 2>/dev/null||echo 0)" = "\$(stat -c %s "\$FILE1")" ]; then
  echo "PASS client-prefetch: file_1 migrated S1->S2 via fitcache_prefetch()"
else
  echo "FAIL client-prefetch: file_1 not migrated to \$DST1"
  echo "--- S2 log (prefetch handler + migrate) ---"; grep -aE "Prefetch|prefetch|migrate" "\$SR"/cwd/fitcache_server_log.\$S2.* 2>/dev/null | tail -15
fi

echo "work dir: \$SR"
EOF
chmod +x "$JOB_DIR/job.sh"
JID=$(sbatch --parsable "$JOB_DIR/job.sh")
echo "migrate compute smoke job: $JID -> $JOB_DIR"
echo "log: $JOB_DIR/migrate_smoke-${JID}.out"
