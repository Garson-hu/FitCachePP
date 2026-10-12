#!/bin/bash
#
# arc_cxl_pool_series.sh <n_gpus> [tag]
#
# One run of the ARC CXL-tier CosmoFlow series. N GPU nodes (one GPU each)
# train through 8 FitCache++ servers on the CXL node, with the memory tier in
# the famfs-backed CXL pool. Mirrors the protocol of the IPDPS ARC runs so the
# result sits next to the PMem bars: train_61440 (n_train=61440, n_valid=1024),
# batch size 2, 5 epochs, cold cache at start, reported value = train.py's
# "Total epoch time" (sum of the five per-epoch times).
#
# Run on the CXL node (c28). The GPU nodes are held by a SLURM job for the
# duration; set CLIENT_NODES to choose them, otherwise the first N idle nodes
# of the site partition are taken — restricted to the CPU-class partitions in
# NODE_CLASS (e.g. "turin", or "siena rome") when that is set.
# FITPP_PURGE_CACHE=0 keeps the pool contents of the previous run instead of
# starting cold.

set -u
N_GPUS="${1:?usage: arc_cxl_pool_series.sh <n_gpus> [tag]}"
TAG="${2:-rep1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh"

# c54: NVIDIA driver broken; c0, c1, c3: InfiniBand link at 2.5 Gb/s instead
# of 100 (probed 2026-10-07 / 10-11).
EXCLUDE_NODES="${EXCLUDE_NODES:-c54 c0 c1 c3}"
if [ -z "${CLIENT_NODES:-}" ]; then
    IDLE=$(sinfo -h -p "$FITPP_SLURM_PARTITION" -t idle -o '%n' | grep -vxF -f <(printf '%s\n' $EXCLUDE_NODES) | sort -u)
    if [ -n "${NODE_CLASS:-}" ]; then
        IDLE=$(comm -12 <(echo "$IDLE") <(sinfo -h -p "${NODE_CLASS// /,}" -o '%n' | sort -u))
    fi
    CLIENT_NODES=$(echo "$IDLE" | head -n "$N_GPUS" | tr '\n' ' ')
fi
read -a NODES <<< "$CLIENT_NODES"
if [ "${#NODES[@]}" -ne "$N_GPUS" ]; then
    echo "ERROR: need $N_GPUS GPU nodes, have ${#NODES[@]} (${CLIENT_NODES:-none idle})" >&2
    exit 1
fi
export CLIENT_NODES

export RESULTS_DIR="${FITPP_RESULTS_ROOT}/arc_cxl_pool_series/gpus${N_GPUS}_${TAG}"
mkdir -p "$RESULTS_DIR"

# Hold the GPU nodes so ssh/horovodrun may start processes on them, unless the
# caller already holds CLIENT_NODES (FITPP_NO_HOLD=1, used by
# arc_cxl_pool_reserved.sbatch, whose own allocation is the hold).
if [ "${FITPP_NO_HOLD:-0}" = "1" ]; then
    echo "[$(date '+%F %T')] using caller-held nodes ${NODES[*]}"
else
    HOLD_HOURS="${HOLD_HOURS:-14}"
    HOLD_JOB=$(sbatch --parsable -p "$FITPP_SLURM_PARTITION" -N "$N_GPUS" -w "$(IFS=,; echo "${NODES[*]}")" \
               -t "${HOLD_HOURS}:00:00" -J fitpp_cxl_clients -o "$RESULTS_DIR/hold-%j.out" --wrap 'sleep infinity')
    trap 'scancel "$HOLD_JOB" 2>/dev/null' EXIT
    echo "[$(date '+%F %T')] hold job $HOLD_JOB on ${NODES[*]} (${HOLD_HOURS} h)"
    until [ "$(squeue -h -j "$HOLD_JOB" -o '%T')" = "RUNNING" ]; do sleep 5; done
fi

export SERVERS=8
export FitCache_DRAM_PATH=/dev/shm/$USER/fitcachepp_cxl_series_dram
export FitCache_DRAM_CAPACITY=0
export FitCache_NVME_PATH=/mnt/local/$USER/fitcachepp_cxl_series_nvme
export FitCache_CXL_PATH=/mnt/famfs/dax2.0/ghu4_deeptier/fitcachepp_cxl_pool
export FitCache_CXL_CAPACITY=$((32 * 1024 * 1024 * 1024))
export FitCache_DATA_DIR="$FITPP_COSMOFLOW_DATA_DEFAULT"
export FITPP_N_TRAIN=61440
export FITPP_N_EPOCHS=5
export FITPP_PURGE_CACHE="${FITPP_PURGE_CACHE:-1}"
# NOTICE level: at INFO every open is logged by 8 servers and every client,
# ~300 MB per run on the quota-limited home filesystem (a 16-GPU run died of
# "Disk quota exceeded" on 2026-10-06). The pool index still proves engagement.
export FitCache_LOG_LEVEL=500

# Sample the training process's resident memory on every client node while
# the run is going: a 1-GPU run was OOM-killed at 122 GB on a 125 GB node
# (2026-10-07), and the growth rate is what we need to see.
( while true; do
      for n in "${NODES[@]}"; do
          ssh -o BatchMode=yes -o ConnectTimeout=10 "$n" \
              'ps -o rss= -C python3 2>/dev/null | sort -n | tail -1' < /dev/null 2>/dev/null \
              | awk -v n="$n" -v t="$(date '+%F %T')" '{printf "%s %s rss_gb=%.1f\n", t, n, $1/1048576}'
      done
      sleep 300
  done >> "$RESULTS_DIR/client_rss.log" 2>&1 ) &
RSS_SAMPLER=$!

"$SCRIPT_DIR/TPDS_FITPP_remote_servers.sh" < /dev/null > "$RESULTS_DIR/launcher.log" 2>&1
RC=$?
kill "$RSS_SAMPLER" 2>/dev/null

# The LD_PRELOAD client leaves one log per python process in the benchmark
# dir; sweep the ones no live process can still be writing.
find "$FITPP_COSMOFLOW_DIR" -maxdepth 1 -name 'fitcache_intercept_log.*' -mmin +5 -delete 2>/dev/null

echo "[$(date '+%F %T')] gpus=$N_GPUS tag=$TAG launcher_rc=$RC"
tr '\r' '\n' < "$RESULTS_DIR"/horovodrun_*.log | grep -E '^\[0\].*(time: [0-9.]+ - [0-9]+s/epoch|Total epoch time)' | sed -E 's/ - loss.*lr: [0-9.e+-]+//'
exit $RC
