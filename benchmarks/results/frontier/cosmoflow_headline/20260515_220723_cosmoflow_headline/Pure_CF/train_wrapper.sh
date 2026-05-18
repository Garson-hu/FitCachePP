#!/bin/bash
cd $FITPP_COSMOFLOW_DIR
 $FITPP_PYTHON_TF \
    $FITPP_COSMOFLOW_DIR/train.py -d \
    --data-dir "$FitCache_DATA_DIR" \
    --n-train 524288 \
    --n-epochs 3
