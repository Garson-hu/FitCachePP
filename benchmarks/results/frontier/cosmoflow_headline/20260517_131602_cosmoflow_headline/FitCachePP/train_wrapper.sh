#!/bin/bash
cd $FITPP_COSMOFLOW_DIR
LD_PRELOAD="$FITPP_CLIENT_LIB" $FITPP_PYTHON_TF \
    $FITPP_COSMOFLOW_DIR/train.py -d \
    --data-dir "$FitCache_DATA_DIR" \
    --n-train 32768 \
    --n-epochs 3
