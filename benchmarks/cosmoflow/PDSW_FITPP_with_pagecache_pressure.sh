#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_pcp
#
# Single-job FitCachePP run under simulated page-cache pressure.
#
# Wraps the standard PDSW_FITPP launcher with a mem_hog sidecar that
# commits ~PCP_HOG_GB GiB of anonymous memory. The kernel then has to
# evict file-backed page cache pages (BeeGFS dataset and FitCache local
# tier files alike) to make room for our committed anonymous pages.
# This pushes the workload into the I/O-bound regime where FitCache's
# local NVMe tier provides a measurable speedup over BeeGFS.
#
# Why this matters: on the rtx4060ti16g nodes (~378 GiB RAM), the
# CosmoFlow n_train=8192 dataset (~50 GiB) fits comfortably in the OS
# page cache after the cold epoch. Pure_CF (no LD_PRELOAD) then reads
# the warm dataset at RAM speed via the page cache, and FitCache's
# LD_PRELOAD adds RPC overhead without any speedup. Committing ~300
# GiB of memory pressure shrinks the available page cache to ~38 GiB,
# below the dataset size, forcing repeated PFS or NVMe reads.
#
# Env vars (all optional; defaults baked in):
#   PCP_HOG_GB      — gigabytes of anonymous memory to commit (default 300)
#   FITPP_PURE_CF   — 1 = no LD_PRELOAD (Pure_CF baseline); 0 = FitCachePP (default 0)
#   FITPP_N_TRAIN   — n_train for train.py (default 8192)
#   FitCache_DATA_DIR — BeeGFS dataset root (inherited; the script enforces
#                       a default if unset)
#   RESULTS_DIR     — per-run output dir
#
# Invocation:
#   sbatch -w c68 --export=PCP_HOG_GB=300,FITPP_PURE_CF=1,FITPP_N_TRAIN=8192,... \
#       PDSW_FITPP_with_pagecache_pressure.sh

set -u

# Resolve site (sets FITPP_REPO).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh"

REPO="$FITPP_REPO"
MEM_HOG="$REPO/benchmarks/util/mem_hog"

if [ ! -x "$MEM_HOG" ]; then
    echo "[pcp] ERROR: mem_hog binary not found at $MEM_HOG; build it first" >&2
    exit 1
fi

HOG_GB="${PCP_HOG_GB:-300}"
echo "[pcp] [$(date -Iseconds)] launching mem_hog with ${HOG_GB} GiB of anonymous memory"

# Launch the hog in the background. Its commit phase will print progress
# to stderr; we redirect to a logfile so the SLURM out file stays focused
# on the training output.
MEM_HOG_LOG="${RESULTS_DIR:-/tmp}/mem_hog_$$.log"
"$MEM_HOG" "$HOG_GB" 0 > "$MEM_HOG_LOG" 2>&1 &
HOG_PID=$!
trap '[ -n "$HOG_PID" ] && kill -TERM "$HOG_PID" 2>/dev/null' EXIT INT TERM

# Wait for the hog to finish its commit phase. The hog logs
# "mem_hog: committed N GiB in Ks" when done. Poll for that line.
echo "[pcp] [$(date -Iseconds)] waiting for mem_hog to finish committing..."
while ! grep -q "mem_hog: committed " "$MEM_HOG_LOG" 2>/dev/null; do
    if ! kill -0 "$HOG_PID" 2>/dev/null; then
        echo "[pcp] ERROR: mem_hog died before committing; check $MEM_HOG_LOG" >&2
        cat "$MEM_HOG_LOG" >&2
        exit 1
    fi
    sleep 5
done
echo "[pcp] [$(date -Iseconds)] mem_hog committed; page cache should now be under pressure"

# Show the effect on the OS for the record.
echo "[pcp] /proc/meminfo MemAvailable/Cached at commit time:"
grep -E '^(MemTotal|MemAvailable|Cached|Buffers|AnonPages):' /proc/meminfo

# Hand off to the standard FitCachePP launcher. Inherit all its env vars
# (FITPP_PURE_CF, FITPP_N_TRAIN, FitCache_DATA_DIR, RESULTS_DIR, etc.).
echo "[pcp] [$(date -Iseconds)] launching PDSW_FITPP.sh under pressure"
"$SCRIPT_DIR/PDSW_FITPP.sh"
RC=$?

echo "[pcp] [$(date -Iseconds)] PDSW_FITPP.sh exited rc=$RC; releasing mem_hog"
kill -TERM "$HOG_PID" 2>/dev/null
wait "$HOG_PID" 2>/dev/null

exit $RC
