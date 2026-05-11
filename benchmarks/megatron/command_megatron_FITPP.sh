#!/bin/bash
#
# command_megatron_FITPP.sh
#
# LD_PRELOAD'd Megatron-LM pretraining command. Invoked by
# PDSW_FITPP_inner.sh on each client rank as the client-side launcher
# when FITCACHE_CLIENT_LAUNCHER points at this script.
#
# This is the Megatron analog of command_CF_FITPP.sh. It assumes:
#   - MEGATRON_TRAIN_CMD is exported as a bash array (built up in
#     PDSW_FITPP_megatron.sh).
#   - MEGATRON_PYTHON points at the Megatron-capable conda env.
#   - FitCache_DATA_DIR is the parent of the .bin/.idx pair so the
#     LD_PRELOAD substring filter catches Megatron's data opens.

set -x
# cd into the Megatron-LM tree so the relative imports in pretrain_gpt.py
# resolve. This mirrors what the IPDPS-style scripts do for CosmoFlow.
cd /home/ghu4/hvac/benchmark/Megatron-LM/

# Substitute the python binary into the front of the train command, so the
# LD_PRELOAD wraps the whole torchrun + python stack.
LD_PRELOAD=/home/ghu4/hvac/FitCachePP/build/src/libfitcache_client.so \
    "${MEGATRON_TRAIN_CMD[@]}"

echo "DONE $(hostname)"
