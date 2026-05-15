#!/bin/bash
# Build a PyTorch + ROCm 6.0 conda env at /ccs/home/ghu4/envs/torch_rocm/.
# Used by Megatron-LM and DINOv2, both of which mmap their data shards;
# these are the workloads that exercise the libfitcache_client.so mmap
# interceptor added 2026-05-15 (commit 85c9527).
#
# Idempotent: re-runs skip what's already done. Logs go to
# /tmp/torch_rocm_env_build.log so /ccs/home/ghu4/envs/ stays env-only.
set -euo pipefail
exec > >(tee /tmp/torch_rocm_env_build.log) 2>&1

echo "=== $(date) start ==="

export http_proxy=http://proxy.ccs.ornl.gov:3128/
export https_proxy=http://proxy.ccs.ornl.gov:3128/

# Same module recipe as the TF env — PrgEnv-gnu so gcc-13 is on PATH,
# rocm/6.0 because that's what we pin libamdhip64.so to, miniforge3 for
# conda. NOTE: do not pipe `module` — that puts it in a subshell and the
# env mutations vanish.
module reset >/dev/null 2>&1 || true
module swap PrgEnv-cray PrgEnv-gnu
module load rocm/6.0.0
module load miniforge3

ENV_PREFIX=/ccs/home/ghu4/envs/torch_rocm
PY=$ENV_PREFIX/bin/python
PIP=$ENV_PREFIX/bin/pip

if [ ! -x "$PY" ]; then
    echo "--- creating env at $ENV_PREFIX ---"
    conda create -p "$ENV_PREFIX" python=3.10 -y -c conda-forge
fi

echo "--- python info ---"
$PY --version
$PIP --version

echo "--- pip install: torch + torchvision for ROCm 6.0 ---"
$PIP install --upgrade pip
# AMD's PyTorch index for ROCm 6.0 ships torch 2.3.x. Use the official
# pytorch.org index since AMD's repo.radeon.com index drops older builds.
$PIP install --no-cache-dir \
    torch==2.3.1+rocm6.0 \
    torchvision==0.18.1+rocm6.0 \
    --index-url https://download.pytorch.org/whl/rocm6.0 2>&1 | tail -15

echo "--- verify torch loads ---"
$PY -c "import torch; print('torch:', torch.__version__, 'hip:', torch.version.hip)" 2>&1 | tail -3

echo "--- pip install: Megatron + DINOv2 minimum deps ---"
# Megatron-LM core deps (without apex; we'll use --no-masked-softmax-fusion
# at run time to avoid the apex requirement for the smoke).
# DINOv2 deps overlap mostly: PIL, numpy, omegaconf, tensorboardx, etc.
$PIP install --no-cache-dir \
    'numpy<2' pyyaml six regex requests sentencepiece nltk \
    pybind11 'protobuf<5' pandas \
    pillow omegaconf hydra-core iopath fvcore \
    tensorboard 2>&1 | tail -10

echo "--- verify Megatron + DINOv2 critical imports ---"
$PY -c "
import torch
import numpy as np
print('torch + numpy import OK')
print('torch.cuda.is_available():', torch.cuda.is_available())
print('numpy mmap availability:', hasattr(np, 'memmap'))
import PIL, omegaconf
print('PIL + omegaconf OK')
" 2>&1 | tail -10

echo "=== $(date) done ==="
