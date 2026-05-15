#!/bin/bash
# Build TF + Horovod + ROCm conda env for CosmoFlow on Frontier.
# Idempotent: re-runs skip what's already done.
set -euo pipefail
exec > >(tee /tmp/cosmoflow_env_build.log) 2>&1

echo "=== $(date) start ==="

export http_proxy=http://proxy.ccs.ornl.gov:3128/
export https_proxy=http://proxy.ccs.ornl.gov:3128/

module reset >/dev/null 2>&1 || true
module swap PrgEnv-cray PrgEnv-gnu 2>&1 | head -3 || true
module load rocm/6.2.4 2>&1 | head -3
module load miniforge3 2>&1 | head -3

ENV_PREFIX=/ccs/home/ghu4/envs/cosmoflow_rocm
PY=$ENV_PREFIX/bin/python
PIP=$ENV_PREFIX/bin/pip

if [ ! -x "$PY" ]; then
    echo "--- creating env at $ENV_PREFIX ---"
    conda create -p "$ENV_PREFIX" python=3.10 -y -c conda-forge
fi

echo "--- python info ---"
$PY --version
$PIP --version

echo "--- pip install: TF for ROCm ---"
$PIP install --upgrade pip
# tensorflow-rocm: AMD's ROCm-built TF wheel. Try the version pinned to ROCm
# 6.2 first; fall back to the latest if pin is unavailable.
$PIP install 'tensorflow-rocm==2.14.0.600' 2>&1 | tail -15 || \
    $PIP install tensorflow-rocm 2>&1 | tail -15

echo "--- verify TF imports ---"
$PY -c "import tensorflow as tf; print('TF:', tf.__version__)" 2>&1 | head -20

echo "--- pip install: cosmoflow deps ---"
$PIP install pyyaml pandas wandb 2>&1 | tail -10

echo "--- install horovod with TF + ROCm bindings ---"
export HOROVOD_WITH_TENSORFLOW=1
export HOROVOD_WITHOUT_PYTORCH=1
export HOROVOD_WITHOUT_MXNET=1
export HOROVOD_GPU_OPERATIONS=NCCL
export HOROVOD_GPU=ROCM
export HOROVOD_ROCM_HOME=$ROCM_PATH
export HOROVOD_RCCL_HOME=$ROCM_PATH
export HOROVOD_GPU_BROADCAST=NCCL
export HOROVOD_GPU_ALLREDUCE=NCCL
export CC=/opt/cray/pe/gcc-native/13/bin/gcc
export CXX=/opt/cray/pe/gcc-native/13/bin/g++
$PIP install --no-cache-dir --no-build-isolation 'horovod==0.28.1' 2>&1 | tail -30

echo "--- verify horovod imports ---"
$PY -c "import horovod.tensorflow.keras as hvd; print('hvd OK')" 2>&1 | head -10

echo "--- install mlperf-logging from local source ---"
$PIP install -e /lustre/orion/gen008/proj-shared/ghu4/envs/mlperf-logging 2>&1 | tail -5 || \
    echo "mlperf-logging install failed (non-blocking)"

echo "=== $(date) done ==="
