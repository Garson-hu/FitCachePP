#!/bin/bash
cd $FITPP_COSMOFLOW_DIR
LD_PRELOAD=/ccs/home/ghu4/new_hvac_copy/build_frontier/src/libhvac_client.so $FITPP_PYTHON_TF \
    $FITPP_COSMOFLOW_DIR/train.py -d \
    --data-dir "$HVAC_DATA_DIR" \
    --n-train 32768 \
    --n-epochs 2
