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

LD_PRELOAD=/home/ghu4/hvac/FitCachePP/build/src/libfitcache_client.so \
    /home/ghu4/hvac/rlibrary/miniconda3/envs/hvac_tf/bin/python3 \
    /home/ghu4/hvac/benchmark/cosmoflow-benchmark-master/train.py -d

echo DONE `hostname`
