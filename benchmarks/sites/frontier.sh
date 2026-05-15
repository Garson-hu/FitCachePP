# benchmarks/sites/frontier.sh
#
# Site config for ORNL Frontier. Lustre PFS = Orion, AMD MI250X GPUs (4 per
# node, 2 GCDs each → 8 logical GPUs), Slingshot interconnect, libfabric ofi
# transport, /mnt/bb/$USER per-node burst-buffer NVMe (provisioned by SLURM
# when the job requests it; mounted writeable on compute nodes only).
#
# Resolution rules picked here:
#   - Repo lives on Orion proj-shared (large quota, persistent across
#     allocations).
#   - log4c built fresh in $HOME (small).
#   - Mercury 2.0.1 is consumed from the spack tree at /sw/frontier/spack-envs
#     (still on disk even though "module load mercury/2.0.1" is no longer
#     exposed; matches what FitCachePP and the IPDPS HVAC code were built
#     against).
#   - cluster registry MUST be on Orion, not /tmp or burst-buffer (per-node).
#   - Python env is a conda env under $HOME/envs/cosmoflow_rocm (TF + Horovod
#     for ROCm 6.2). Build by /ccs/home/ghu4/envs/build_cosmoflow_env.sh.

# ---- repo layout ----
export FITPP_REPO=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP
export FITPP_BUILD_DIR="${FITPP_REPO}/build"
export FITPP_SERVER_BIN="${FITPP_BUILD_DIR}/src/fitcache_server"
export FITPP_CLIENT_LIB="${FITPP_BUILD_DIR}/src/libfitcache_client.so"
export FITPP_RESULTS_ROOT="${FITPP_REPO}/benchmarks/results"

# ---- external benchmark sources ----
# CosmoFlow source already cloned under proj-shared/ghu4/benchmark/.
export FITPP_COSMOFLOW_DIR=/lustre/orion/gen008/proj-shared/ghu4/benchmark/cosmoflow-benchmark
# Megatron / DINOv2 left blocked-by-mmap (per repo-level notes); point at the
# in-tree clones for completeness, but don't expect them to fire.
export FITPP_MEGATRON_DIR=/lustre/orion/gen008/proj-shared/ghu4/benchmark/Megatron-DeepSpeed-ORNL
export FITPP_DINOV2_DIR=""   # not cloned on Frontier yet

# ---- Python environments ----
# TF + Horovod for ROCm 6.2, created at env-bootstrap time. Will not exist
# until /ccs/home/ghu4/envs/build_cosmoflow_env.sh finishes.
export FITPP_PYTHON_TF=/ccs/home/ghu4/envs/cosmoflow_rocm/bin/python3
export FITPP_PYTHON_TF_BIN_DIR=/ccs/home/ghu4/envs/cosmoflow_rocm/bin
# PyTorch + ROCm 6.0 env for Megatron-LM + DINOv2 (both PyTorch-based,
# both mmap-using → exercise the libfitcache_client.so mmap interceptor).
# Created by scripts/env/build_torch_rocm_env.sh.
export FITPP_PYTHON_TORCH=/ccs/home/ghu4/envs/torch_rocm/bin/python3
export FITPP_PYTHON_DINOV2="$FITPP_PYTHON_TORCH"

# ---- Mercury + log4c ----
# Mercury 2.0.1 = the version FitCachePP was developed against on ARC.
# The system spack install path is preserved even though the module-spider
# listing only surfaces 2.1.0 and 2.2.0 now; the .so files + headers +
# pkgconfig still live at the path below, and that's what we link against.
export FITPP_MERCURY_LIB_DIR=/sw/frontier/spack-envs/base/opt/cray-sles15-zen3/cce-15.0.0/mercury-2.0.1-4okvpnqnw7aejnvzoevcnu5h6x7hb7a7/lib
export FITPP_MERCURY_PKGCONFIG_DIR=/sw/frontier/spack-envs/base/opt/cray-sles15-zen3/cce-15.0.0/mercury-2.0.1-4okvpnqnw7aejnvzoevcnu5h6x7hb7a7/lib/pkgconfig
# Mercury 2.0.1 was built without command-line tools, so no bin dir; leave the
# variable set to the lib dir (PATH-prepend a no-op).
export FITPP_MERCURY_BIN_DIR="${FITPP_MERCURY_LIB_DIR}"

# log4c 1.2.4 built fresh in $HOME (under-quota, ~3 MB):
export FITPP_LOG4C_LIB_DIR=/ccs/home/ghu4/log4c-1.2.4/install/lib
export FITPP_LOG4C_PKGCONFIG_DIR=/ccs/home/ghu4/log4c-1.2.4/install/lib/pkgconfig

# ---- PFS dataset paths ----
# Datasets live on proj-shared/ghu4/data. Mini variant has train/ + validation/
# only (1024 train files, 307 MB — fits comfortably). Full 169 GB train_61440/
# is staged by extracting cosmoUniverse_2019_05_4parE_tf_v2.tar (~121 GB, 1.6 TB
# expanded); not present yet on 2026-05-14.
export FITPP_PFS_DATA_ROOT=/lustre/orion/gen008/proj-shared/ghu4/data
# cosmo.py auto-appends /train and /validation to data_dir, so point at the
# parent dataset dir, not the train/ subdir.
export FITPP_COSMOFLOW_DATA_DEFAULT="${FITPP_PFS_DATA_ROOT}/cosmoUniverse_2019_05_4parE_tf_v2_mini"
export FITPP_COSMOFLOW_DATA_SMOKE="${FITPP_PFS_DATA_ROOT}/cosmoUniverse_2019_05_4parE_tf_v2_mini"
# Megatron prep is mmap-limited; leave unset until that gap is closed.
export FITPP_MEGATRON_TOKENIZER_DIR=""
export FITPP_MEGATRON_CORPUS_PREFIX=""

# ---- local cache device roots ----
# /mnt/bb/$USER is Frontier's per-node burst-buffer NVMe. The SLURM job has to
# request it via --constraint=nvme (or equivalent) for the mount to appear;
# the launcher script does NOT pass that constraint by default — set
# SBATCH_EXTRA_DIRECTIVES or pass it on the sbatch CLI.
export FITPP_LOCAL_CACHE_ROOT="/mnt/bb/$USER"
export FITPP_PMEM_CACHE_ROOT=""   # Frontier has no PMem
# Cluster registry: must be on a filesystem ALL nodes can see. Orion
# proj-shared is the only fit.
export FITPP_PFS_REGISTRY_ROOT=/lustre/orion/gen008/proj-shared/ghu4/fitcachepp_registry

# ---- SLURM ----
export FITPP_SLURM_PARTITION="batch"
export FITPP_SLURM_ACCOUNT="gen008"
# Burst-buffer mount needs the nvme feature; request it so /mnt/bb/$USER
# exists on the compute node. (Frontier docs: --constraint=nvme.)
export FITPP_SLURM_EXTRA_DIRECTIVES="#SBATCH -C nvme"
export FITPP_MAIL_USER=""

# ---- module loads ----
# Loaded by _resolve.sh via `eval`. Must:
#   - move off PrgEnv-cray (defaults to CrayClang) onto PrgEnv-gnu (gcc 13.2)
#     because the Cray wrapper strips one of mercury.pc's two -I paths and
#     breaks the build; gcc-13 direct does not.
#   - load rocm/6.2.4 so the Python env's tensorflow-rocm wheel can find
#     libamdhip64 / librccl etc. at runtime.
#   - load miniforge3 to get `conda activate` available; the activate is done
#     inside the cosmoflow launcher (not the site config) because activating
#     an env from a sourced file is brittle.
#   - libfabric/cray-mpich are already in the PrgEnv-gnu base environment.
#   - drop darshan-runtime (LD_PRELOAD-incompatible with FitCache's own
#     preload).
export FITPP_MODULE_LOADS='
module reset
module swap PrgEnv-cray PrgEnv-gnu
module load rocm/6.0.0
module load miniforge3
module unload darshan-runtime
'

# ---- launcher ----
# Frontier compute nodes have 4 MI250X = 8 logical GPUs. Single-GPU sanity
# runs use horovodrun bound to 1 GPU; multi-GPU + multi-node runs use srun.
# Default to horovodrun for the per-job baseline.
export FITPP_LAUNCHER_KIND="horovodrun"

# ---- defaults ----
# Headline sanity run is single-GPU: 1 GCD on 1 node. Multi-GPU comes later.
export FITPP_GPUS_PER_NODE_DEFAULT=1
export FITPP_SERVERS_PER_NODE_DEFAULT=4
