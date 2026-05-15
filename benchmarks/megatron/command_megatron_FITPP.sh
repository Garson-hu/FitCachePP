#!/bin/bash
#
# command_megatron_FITPP.sh
#
# LD_PRELOAD'd Megatron-LM pretraining command. Invoked by
# TPDS_FITPP_inner.sh as the client-side launcher when
# FITCACHE_CLIENT_LAUNCHER points here.
#
# Assumes TPDS_FITPP_megatron.sh has exported MEGATRON_TRAIN_CMD (bash array)
# and MEGATRON_PYTHON.

set -x
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/../sites" ]; then
    if [ -n "${FITPP_REPO:-}" ] && [ -d "$FITPP_REPO/benchmarks/sites" ]; then
        SCRIPT_DIR="$FITPP_REPO/benchmarks/megatron"
    fi
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh"

# cd into the Megatron-LM tree so relative imports in pretrain_gpt.py
# resolve (mirrors what command_CF_FITPP.sh does for CosmoFlow).
cd "$FITPP_MEGATRON_DIR/"

LD_PRELOAD="$FITPP_CLIENT_LIB" \
    "${MEGATRON_TRAIN_CMD[@]}"

echo "DONE $(hostname)"
