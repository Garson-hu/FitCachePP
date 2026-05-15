#!/bin/bash
#
# command_CF_FITPP.sh
#
# LD_PRELOAD'd CosmoFlow training command, FitCache++ variant. Invoked by
# horovodrun on each client rank from the TPDS_FITPP*.sh launchers. Mirrors
# the existing /home/ghu4/hvac/benchmark/cosmoflow-benchmark-master/command_MS_Read.sh
# but swaps to the FitCache++ libfitcache_client.so so the cross-job code paths
# (FitCache_CROSS_JOB=1, cluster registry, peer-lookup fanout) are exercised
# instead of the IPDPS MS_READ shim.

set -x
# Resolve site (FITPP_COSMOFLOW_DIR / FITPP_PYTHON_TF / FITPP_CLIENT_LIB).
# horovodrun copies us to a temp dir under sbatch, so apply the same fallback
# as TPDS_FITPP.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/../sites" ]; then
    if [ -n "${FITPP_REPO:-}" ] && [ -d "$FITPP_REPO/benchmarks/sites" ]; then
        SCRIPT_DIR="$FITPP_REPO/benchmarks/cosmoflow"
    fi
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh"

# train.py reads configs/cosmo.yaml via a CWD-relative path, so cd into the
# cosmoflow benchmark dir before launching. Mirrors what the IPDPS TPDS_*.sh
# achieves implicitly because they're sbatched from that dir.
cd "$FITPP_COSMOFLOW_DIR"/

# --data-dir override forces train.py to read from the SAME path the FitCache
# LD_PRELOAD client filters on (FitCache_DATA_DIR). Without this, configs/cosmo.yaml's
# default data_dir (train_1024) is used and the LD_PRELOAD filter at
# fitcache_client.cpp:116 doesn't match — every read passes through to
# BeeGFS direct and the FitCache server pathway stays dormant (root cause
# of the zero-Open-RPC cluster runs on 2026-05-11).
# N_TRAIN override: caller (the outer TPDS_FITPP*.sh script) sets
# FITPP_N_TRAIN to scale the workload. Default 1024 = the configs/cosmo.yaml
# default (small smoke). For real comparisons against the IPDPS published
# numbers, set FITPP_N_TRAIN=61440 (the full dataset IPDPS used). For a
# faster-iterating comparison that still stresses I/O meaningfully, 8192
# is a good middle ground (~8x the cold-epoch I/O cost of 1024 but
# 8x faster than 61440).
N_TRAIN_ARG=()
if [ -n "${FITPP_N_TRAIN:-}" ]; then
    N_TRAIN_ARG=(--n-train "$FITPP_N_TRAIN")
fi
# FITPP_SEED override — different seeds across jobs in the two-job
# concurrent cross-job-sharing run so the two jobs access files in
# DIFFERENT orders. With the default --seed=0 in both jobs, they race
# on the same file at the same time, peer_lookup always sees an empty
# cache (file not yet promoted on either side), and cross-job sharing
# never fires. Different seeds give Job A a chance to populate the
# cache BEFORE Job B asks for the file.
SEED_ARG=()
if [ -n "${FITPP_SEED:-}" ]; then
    SEED_ARG=(--seed "$FITPP_SEED")
fi
# FITPP_N_EPOCHS override — drop from the cosmo.yaml default of 5 down to e.g.
# 3 when running at n_train=61440 so the wall-clock per pilot stays in a few
# hours instead of ~9 h. The cold+warm signal lands within the first 2 epochs.
EPOCHS_ARG=()
if [ -n "${FITPP_N_EPOCHS:-}" ]; then
    EPOCHS_ARG=(--n-epochs "$FITPP_N_EPOCHS")
fi

if [ "${FITPP_PURE_CF:-0}" = "1" ]; then
    # Pure_CF baseline: no LD_PRELOAD, no FitCache. train.py reads PFS
    # directly via the standard POSIX path. Same --data-dir + --n-train
    # so the only variable vs FitCachePP is the cache pathway itself.
    echo "[command_CF_FITPP.sh] FITPP_PURE_CF=1: running WITHOUT LD_PRELOAD (Pure_CF baseline)"
    "$FITPP_PYTHON_TF" \
        "$FITPP_COSMOFLOW_DIR"/train.py -d \
        --data-dir "$FitCache_DATA_DIR" \
        "${N_TRAIN_ARG[@]}" \
        "${EPOCHS_ARG[@]}" \
        "${SEED_ARG[@]}"
else
    LD_PRELOAD="$FITPP_CLIENT_LIB" \
        "$FITPP_PYTHON_TF" \
        "$FITPP_COSMOFLOW_DIR"/train.py -d \
        --data-dir "$FitCache_DATA_DIR" \
        "${N_TRAIN_ARG[@]}" \
        "${EPOCHS_ARG[@]}" \
        "${SEED_ARG[@]}"
fi

echo DONE `hostname`
