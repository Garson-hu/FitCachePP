#!/bin/bash
set -e
module load PrgEnv-gnu cmake/3.27.9 rocm/6.0.0 cray-mpich/8.1.31 craype-accel-amd-gfx90a gcc-native/13.2 2>&1 | tail -2

ENVPY=/ccs/home/ghu4/envs/cosmoflow_rocm/bin/python
ENVPIP=/ccs/home/ghu4/envs/cosmoflow_rocm/bin/pip

export AMDGPU_TARGETS=gfx90a
export GPU_TARGETS=gfx90a
export PYTORCH_ROCM_ARCH=gfx90a
export ROCM_PATH=/opt/rocm-6.0.0
export HIP_PATH=$ROCM_PATH
export HIP_PLATFORM=amd
export PATH=$ROCM_PATH/bin:/ccs/home/ghu4/envs/cosmoflow_rocm/bin:$PATH
export LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:$ROCM_PATH/rccl/lib:$LD_LIBRARY_PATH

export HOROVOD_WITH_TENSORFLOW=1
export HOROVOD_WITHOUT_PYTORCH=1
export HOROVOD_WITHOUT_MXNET=1
# Only specify GPU_OPERATIONS (not per-op overrides) — horovod-0.28 errors if both are set.
export HOROVOD_GPU_OPERATIONS=NCCL
export HOROVOD_GPU=ROCM
export HOROVOD_ROCM_HOME=$ROCM_PATH
export HOROVOD_RCCL_HOME=$ROCM_PATH/rccl
export HOROVOD_RCCL_INCLUDE=$ROCM_PATH/include/rccl
export HOROVOD_RCCL_LIB=$ROCM_PATH/rccl/lib
export HOROVOD_NCCL_HOME=$HOROVOD_RCCL_HOME
export HOROVOD_NCCL_INCLUDE=$HOROVOD_RCCL_INCLUDE
export HOROVOD_NCCL_LIB=$HOROVOD_RCCL_LIB
export HOROVOD_WITH_MPI=1
export HOROVOD_WITH_GLOO=1

# Force horovod's CMake to use the GCC-13 module-loaded compiler, not /usr/bin/g++.
GCC13=$(which gcc-13 2>/dev/null || which gcc)
GPP13=$(which g++-13 2>/dev/null || which g++)
echo "compilers: CC=$GCC13  CXX=$GPP13"
$GCC13 --version | head -1
$GPP13 --version | head -1

export CC=$GCC13
export CXX=$GPP13
# Horovod's cmake invocation does NOT forward CC/CXX through (setup.py
# constructs its own cmake argv), so we need CMAKE_ARGS to pump them in.
export CMAKE_ARGS="-DCMAKE_C_COMPILER=$GCC13 -DCMAKE_CXX_COMPILER=$GPP13"

$ENVPIP uninstall -y horovod 2>&1 | tail -3 || true

cd /lustre/orion/gen008/proj-shared/ghu4/build/horovod_src/horovod-0.28.1
rm -rf build/ horovod/tensorflow/mpi_lib*.so 2>/dev/null

echo "=== STARTING BUILD ==="; date
$ENVPY setup.py build_ext --inplace 2>&1
RC=$?
echo "=== build_ext returncode=$RC ==="; date

if [ $RC -eq 0 ]; then
    $ENVPIP install --no-build-isolation --no-deps . 2>&1 | tail -30
    $ENVPY -c "import horovod.tensorflow as hvd; print('nccl_built:', hvd.nccl_built()); print('rocm_built:', hvd.rocm_built()); print('mpi_built:', hvd.mpi_built()); print('gloo_built:', hvd.gloo_built())" 2>&1
fi
