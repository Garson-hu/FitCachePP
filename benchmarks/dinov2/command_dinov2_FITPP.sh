#!/bin/bash
#
# command_dinov2_FITPP.sh
#
# LD_PRELOAD'd DINOv2 SSL pretraining command. Invoked by
# PDSW_FITPP_inner.sh as the client-side launcher when
# FITCACHE_CLIENT_LAUNCHER points here.

set -x
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/../sites" ]; then
    if [ -n "${FITPP_REPO:-}" ] && [ -d "$FITPP_REPO/benchmarks/sites" ]; then
        SCRIPT_DIR="$FITPP_REPO/benchmarks/dinov2"
    fi
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh"

cd "$FITPP_DINOV2_DIR/"

LD_PRELOAD="$FITPP_CLIENT_LIB" \
    "${DINOV2_TRAIN_CMD[@]}"

echo "DONE $(hostname)"
