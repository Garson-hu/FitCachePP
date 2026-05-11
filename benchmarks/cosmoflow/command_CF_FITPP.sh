#!/bin/bash
#
# command_CF_FITPP.sh
#
# LD_PRELOAD'd CosmoFlow training command, FitCache++ variant. Invoked by
# horovodrun on each client rank from the PDSW_FITPP*.sh launchers. Mirrors
# the existing /home/ghu4/hvac/benchmark/cosmoflow-benchmark-master/command_MS_Read.sh
# but swaps to the FitCache++ libfitcache_client.so so the cross-job code paths
# (FitCache_CROSS_JOB=1, cluster registry, peer-lookup fanout) are exercised
# instead of the IPDPS MS_READ shim.

set -x
# train.py reads configs/cosmo.yaml via a CWD-relative path, so cd into the
# cosmoflow benchmark dir before launching. Mirrors what the IPDPS PDSW_*.sh
# achieves implicitly because they're sbatched from that dir.
cd /home/ghu4/hvac/benchmark/cosmoflow-benchmark-master/

# --data-dir override forces train.py to read from the SAME path the FitCache
# LD_PRELOAD client filters on (FitCache_DATA_DIR). Without this, configs/cosmo.yaml's
# default data_dir (train_1024) is used and the LD_PRELOAD filter at
# fitcache_client.cpp:116 doesn't match — every read passes through to
# BeeGFS direct and the FitCache server pathway stays dormant (root cause
# of the zero-Open-RPC cluster runs on 2026-05-11).
LD_PRELOAD=/home/ghu4/hvac/FitCachePP/build/src/libfitcache_client.so \
    /home/ghu4/hvac/rlibrary/miniconda3/envs/hvac_tf/bin/python3 \
    /home/ghu4/hvac/benchmark/cosmoflow-benchmark-master/train.py -d \
    --data-dir "$FitCache_DATA_DIR"

echo DONE `hostname`
