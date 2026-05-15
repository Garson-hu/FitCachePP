#!/bin/bash
set -euo pipefail
exec > >(tee -a /tmp/cosmoflow_env_build.log) 2>&1

echo "=== $(date) continuing build (post-TF) ==="

export http_proxy=http://proxy.ccs.ornl.gov:3128/
export https_proxy=http://proxy.ccs.ornl.gov:3128/

# NB: Don't pipe `module` output — piping forces a subshell and the env
# mutations (ROCM_PATH, LD_LIBRARY_PATH, PATH) never reach the parent script.
module reset >/dev/null 2>&1 || true
module swap PrgEnv-cray PrgEnv-gnu
module load rocm/6.2.4
module load miniforge3

echo "ROCM_PATH=${ROCM_PATH:-UNSET}"
echo "PATH starts: $(echo $PATH | tr ':' '\n' | head -3 | tr '\n' ' ')"

PY=/ccs/home/ghu4/envs/cosmoflow_rocm/bin/python
PIP=/ccs/home/ghu4/envs/cosmoflow_rocm/bin/pip

echo "--- cosmoflow deps (probably already installed) ---"
$PIP install --quiet pyyaml pandas wandb 2>&1 | tail -5 || true

echo "--- horovod with TF + ROCm bindings ---"
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
ls -la $ROCM_PATH/lib/librccl.so* 2>&1 | head -3 || true
$PIP install --no-cache-dir --no-build-isolation 'horovod==0.28.1' 2>&1 | tail -50

echo "--- verify hvd ---"
$PY -c "import horovod.tensorflow.keras as hvd; print('hvd OK')" 2>&1 | tail -5

echo "--- mlperf-logging from local source ---"
$PIP install -e /lustre/orion/gen008/proj-shared/ghu4/envs/mlperf-logging 2>&1 | tail -5 || \
    echo "(mlperf install failed; non-blocking)"

echo "=== $(date) continue done ==="
