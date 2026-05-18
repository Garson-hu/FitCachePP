#!/bin/bash
cd $FITPP_COSMOFLOW_DIR
 $FITPP_PYTHON_TF \
    $FITPP_COSMOFLOW_DIR/train.py -d \
    --data-dir "$FitCache_DATA_DIR" \
    --n-train 32768 \
    --n-epochs 2
