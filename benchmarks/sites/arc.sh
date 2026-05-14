# benchmarks/sites/arc.sh
#
# Site config for the NCSU ARC cluster (BeeGFS PFS, rtx4060ti16g partition,
# /mnt/local NVMe per compute node, /mnt/fsdax PMem on c35). Mirrors the
# values that lived in PDSW_FITPP.sh / PDSW_FITPP_inner.sh / command_CF_FITPP.sh
# before the multi-site refactor.

# ---- repo layout ----
export FITPP_REPO=/home/ghu4/hvac/FitCachePP
export FITPP_BUILD_DIR="${FITPP_REPO}/build"
export FITPP_SERVER_BIN="${FITPP_BUILD_DIR}/src/fitcache_server"
export FITPP_CLIENT_LIB="${FITPP_BUILD_DIR}/src/libfitcache_client.so"
export FITPP_RESULTS_ROOT="${FITPP_REPO}/benchmarks/results"

# ---- external benchmark sources (these are SEPARATE repos cloned alongside) ----
export FITPP_COSMOFLOW_DIR=/home/ghu4/hvac/benchmark/cosmoflow-benchmark-master
export FITPP_MEGATRON_DIR=/home/ghu4/hvac/benchmark/Megatron-LM
export FITPP_DINOV2_DIR=/home/ghu4/hvac/benchmark/dinov2

# ---- Python environments ----
# Conda env with TensorFlow + Horovod + GPUv2 (for CosmoFlow / DeepCAM).
export FITPP_PYTHON_TF=/home/ghu4/hvac/rlibrary/miniconda3/envs/hvac_tf/bin/python3
export FITPP_PYTHON_TF_BIN_DIR=/home/ghu4/hvac/rlibrary/miniconda3/envs/hvac_tf/bin
# Conda env with PyTorch (for Megatron-LM + DINOv2 — even though both are
# currently blocked by the mmap-vs-LD_PRELOAD architectural gap).
export FITPP_PYTHON_TORCH=/home/ghu4/hvac/rlibrary/miniconda3/envs/dpu_torch/bin/python3
export FITPP_PYTHON_DINOV2=/home/ghu4/hvac/rlibrary/miniconda3/envs/dinov2/bin/python3

# ---- Mercury + log4c (linked into FitCache servers + client lib) ----
export FITPP_MERCURY_LIB_DIR=/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export FITPP_MERCURY_PKGCONFIG_DIR=/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export FITPP_MERCURY_BIN_DIR=/home/ghu4/hvac/mercury-2.0.1/build/bin
export FITPP_LOG4C_LIB_DIR=/home/ghu4/hvac/log4c-1.2.4/install/lib
export FITPP_LOG4C_PKGCONFIG_DIR=/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig

# ---- PFS dataset paths ----
# Root the launchers look under for any dataset; specific datasets are full
# paths because we have several variants (train_1024, train_8192, train_61440)
# living side by side.
export FITPP_PFS_DATA_ROOT=/mnt/beegfs/ghu4/hvac
export FITPP_COSMOFLOW_DATA_DEFAULT="${FITPP_PFS_DATA_ROOT}/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440"
export FITPP_COSMOFLOW_DATA_SMOKE="${FITPP_PFS_DATA_ROOT}/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_1024"
# Megatron preprocessed corpus (mmap-based, currently dormant).
export FITPP_MEGATRON_TOKENIZER_DIR="${FITPP_PFS_DATA_ROOT}/megatron_assets"
export FITPP_MEGATRON_CORPUS_PREFIX="${FITPP_PFS_DATA_ROOT}/megatron_pile_train_001/pile_slice_text_document_text_document"

# ---- local cache device roots ----
# /mnt/local on rtx4060ti16g nodes is a 3.5 TB NVMe (real per-node disk, not
# tmpfs). The cluster registry directory lives on BeeGFS.
export FITPP_LOCAL_CACHE_ROOT=/mnt/local/ghu4
export FITPP_PMEM_CACHE_ROOT=/mnt/fsdax/ghu4   # only mounted on c35
export FITPP_PFS_REGISTRY_ROOT=/mnt/beegfs/ghu4

# ---- SLURM ----
# rtx4060ti16g is the single-GPU partition; c66/c67/c68 etc. nodes have one
# RTX 4060 Ti each. The all/cascade partitions are for non-GPU work.
export FITPP_SLURM_PARTITION=rtx4060ti16g
export FITPP_SLURM_ACCOUNT=""          # no account billing on arc
export FITPP_SLURM_EXTRA_DIRECTIVES="" # no extra constraints on arc
export FITPP_MAIL_USER=""              # opt-in only; leaving empty so no SBATCH --mail-user

# ---- module loads + launcher ----
# arc nodes don't use environment-modules; everything's in PATH already.
export FITPP_MODULE_LOADS=""
# CosmoFlow uses Horovod for distributed; single-node here.
export FITPP_LAUNCHER_KIND="horovodrun"

# ---- defaults ----
export FITPP_SERVERS_PER_NODE_DEFAULT=4
export FITPP_GPUS_PER_NODE_DEFAULT=1
