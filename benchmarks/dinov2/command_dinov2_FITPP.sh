#!/bin/bash
#
# command_dinov2_FITPP.sh
#
# LD_PRELOAD'd DINOv2 SSL pretraining command. Invoked by
# PDSW_FITPP_inner.sh when FITCACHE_CLIENT_LAUNCHER points at this script.

set -x
cd /home/ghu4/hvac/benchmark/dinov2/

LD_PRELOAD=/home/ghu4/hvac/FitCachePP/build/src/libfitcache_client.so \
    "${DINOV2_TRAIN_CMD[@]}"

echo "DONE $(hostname)"
