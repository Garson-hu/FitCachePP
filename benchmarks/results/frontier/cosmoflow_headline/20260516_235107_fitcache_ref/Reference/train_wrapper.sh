#!/bin/bash
cd $FITPP_COSMOFLOW_DIR
LD_PRELOAD=/lustre/orion/gen008/proj-shared/ghu4/FitCache_Frontier/build_v2/src/libhvac_client.so $FITPP_PYTHON_TF \
    $FITPP_COSMOFLOW_DIR/train.py -d \
    --data-dir "$HVAC_DATA_DIR" \
    --n-train 8192 \
    --n-epochs 2
