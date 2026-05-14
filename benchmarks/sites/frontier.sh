# benchmarks/sites/frontier.sh
#
# Site config for ORNL Frontier (Lustre PFS / Orion, SchedMD SLURM, AMD MI250X
# GPUs, Slingshot interconnect). All TODO markers must be filled in once we
# have an allocation and the FitCache++ build is in place on Frontier.
#
# Frontier specifics that bite if forgotten:
#   - Use $MEMBERWORK/<proj> for non-PFS work scratch, $PROJWORK/<proj> for
#     shared per-project storage, /lustre/orion/<proj>/scratch/<user> for
#     /-prefixed canonical scratch path.
#   - module load PrgEnv-gnu + a rocm module before building anything.
#   - jsrun is the launcher on Frontier-class systems instead of mpirun;
#     for single-node Horovod runs, you can usually still use horovodrun
#     bound to one node's worth of GPUs via -H, but multi-node needs jsrun
#     or srun with appropriate hwloc binding.
#   - Cluster-registry path MUST be on Lustre (Orion), not on $MEMBERWORK.

# ---- repo layout ----
# TODO: set to wherever you cloned FitCachePP. On Frontier the project area
#       is typically /lustre/orion/<proj>/scratch/<user> or $HOME (smaller).
export FITPP_REPO="$HOME/FitCachePP"   # TODO: adjust
export FITPP_BUILD_DIR="${FITPP_REPO}/build"
export FITPP_SERVER_BIN="${FITPP_BUILD_DIR}/src/fitcache_server"
export FITPP_CLIENT_LIB="${FITPP_BUILD_DIR}/src/libfitcache_client.so"
export FITPP_RESULTS_ROOT="${FITPP_REPO}/benchmarks/results"

# ---- external benchmark sources ----
# TODO: clone or symlink these next to FitCachePP, or change the paths here.
export FITPP_COSMOFLOW_DIR="$HOME/cosmoflow-benchmark-master"   # TODO
export FITPP_MEGATRON_DIR="$HOME/Megatron-LM"                   # TODO
export FITPP_DINOV2_DIR="$HOME/dinov2"                          # TODO

# ---- Python environments ----
# TODO: point at Frontier's Python (likely a cray-python or a personal conda
# env in $MEMBERWORK). The PYTHON_TF binary must have TF + Horovod with ROCm
# bindings; CosmoFlow needs it. PYTHON_TORCH must have PyTorch ROCm.
export FITPP_PYTHON_TF="$HOME/.conda/envs/cosmoflow_rocm/bin/python3"  # TODO
export FITPP_PYTHON_TF_BIN_DIR="$(dirname "$FITPP_PYTHON_TF")"
export FITPP_PYTHON_TORCH="$HOME/.conda/envs/torch_rocm/bin/python3"   # TODO
export FITPP_PYTHON_DINOV2="$FITPP_PYTHON_TORCH"

# ---- Mercury + log4c ----
# TODO: build Mercury for the Slingshot fabric (ofi+verbs or ofi+cxi) and
# log4c, then point at the install dirs.
export FITPP_MERCURY_LIB_DIR="$HOME/local/mercury/lib"          # TODO
export FITPP_MERCURY_PKGCONFIG_DIR="$HOME/local/mercury/lib/pkgconfig"  # TODO
export FITPP_MERCURY_BIN_DIR="$HOME/local/mercury/bin"          # TODO
export FITPP_LOG4C_LIB_DIR="$HOME/local/log4c/lib"              # TODO
export FITPP_LOG4C_PKGCONFIG_DIR="$HOME/local/log4c/lib/pkgconfig"  # TODO

# ---- PFS dataset paths ----
# Orion is mounted at /lustre/orion. Project scratch is the standard place
# for datasets that exceed home quota.
# TODO: replace <proj> with your Frontier allocation code (e.g., CSC123).
export FITPP_PFS_DATA_ROOT="/lustre/orion/<proj>/scratch/$USER/datasets"  # TODO
export FITPP_COSMOFLOW_DATA_DEFAULT="${FITPP_PFS_DATA_ROOT}/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440"
export FITPP_COSMOFLOW_DATA_SMOKE="${FITPP_PFS_DATA_ROOT}/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_1024"
export FITPP_MEGATRON_TOKENIZER_DIR="${FITPP_PFS_DATA_ROOT}/megatron_assets"
export FITPP_MEGATRON_CORPUS_PREFIX="${FITPP_PFS_DATA_ROOT}/megatron_pile_train_001/pile_slice_text_document_text_document"

# ---- local cache device roots ----
# Frontier compute nodes have NVMe (the "node-local burst buffer" / /tmp on
# tmpfs OR a per-node /mnt/bb/<userid> burst buffer; check current docs).
# TODO: point at whichever exists on the partition you're running on.
export FITPP_LOCAL_CACHE_ROOT="/tmp/$USER"                       # TODO
export FITPP_PMEM_CACHE_ROOT=""                                  # Frontier doesn't have PMem; leave empty
export FITPP_PFS_REGISTRY_ROOT="/lustre/orion/<proj>/scratch/$USER/fitcachepp_registry"  # TODO

# ---- SLURM ----
# Frontier uses SLURM with explicit account billing. Pick a partition the
# experiment fits in: 'batch' (long jobs), 'extended' (multi-day), 'debug'
# (smoke tests). Frontier's 'batch' wall-clock limit is 12 h.
export FITPP_SLURM_PARTITION="batch"          # TODO if not batch
export FITPP_SLURM_ACCOUNT="<PROJ>"           # TODO required on Frontier
export FITPP_SLURM_EXTRA_DIRECTIVES=""        # e.g., "#SBATCH --constraint=nvme"
export FITPP_MAIL_USER=""                     # optional

# ---- module loads ----
# Frontier WILL fail if you don't load PrgEnv-gnu (or cray) before running
# anything that links cray-mpich. ROCm load needs to match what TF/PyTorch
# were built against.
export FITPP_MODULE_LOADS='
module reset
module load PrgEnv-gnu
module load rocm/5.7.1
module load cray-python
module load craype-accel-amd-gfx90a
'   # TODO: confirm versions current as of your run date

# ---- launcher ----
# srun is the canonical Frontier launcher and binds correctly with cgroups.
# horovodrun works for single-node but srun + horovod-on-srun is preferred.
export FITPP_LAUNCHER_KIND="srun"  # or "horovodrun" for single-node smoke

# ---- defaults ----
# Frontier compute nodes have 8 MI250X GCDs per node (4 GPUs × 2 GCDs).
# Treat each GCD as one logical GPU for distributed training.
export FITPP_GPUS_PER_NODE_DEFAULT=8
export FITPP_SERVERS_PER_NODE_DEFAULT=4  # same as arc; not GPU-coupled
