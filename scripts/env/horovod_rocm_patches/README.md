# Horovod 0.28.1 + ROCm 6.0 + RCCL build patches (Frontier)

When `pip install horovod==0.28.1` against a stock TF-ROCm 2.14 env on
Frontier, the build falls through to **CPU-only collectives** (gloo+MPI). That
silently kills multi-GPU training under FitCachePP — the
`hvd.allreduce` ping-pongs every gradient through host memory and
LD_PRELOAD jitter on one rank trips the 60s Horovod stall_inspector.

The fix is to rebuild horovod with `HOROVOD_GPU_OPERATIONS=NCCL` +
`HOROVOD_GPU=ROCM` so collectives use RCCL directly on the GCDs. Upstream
horovod-0.28.1 has **three** Frontier/ROCm-6.0-incompatible bugs that
prevent that build, plus two pip-orchestration issues:

1. **Compiler picked**: CMake ignored `CC`/`CXX` env vars and grabbed
   `/usr/bin/g++ 7.5.0` instead of the module-loaded `gcc-native/13.2`.
   Fix: pass `-DCMAKE_C_COMPILER=$(which gcc)` and
   `-DCMAKE_CXX_COMPILER=$(which g++)` via the `CMAKE_ARGS` env var so
   horovod's setup.py-driven cmake invocation forwards them.

2. **`HOROVOD_GPU_OPERATIONS` AND `HOROVOD_GPU_ALLREDUCE` conflict**.
   `cmake/Utilities.cmake:66` aborts if both are set. Set only one
   (`HOROVOD_GPU_OPERATIONS=NCCL`); drop the per-op overrides.

3. **`hip_add_library` undefined on ROCm 6.x**. The macro lives in the
   legacy `FindHIP.cmake` module at
   `/opt/rocm-X/lib/cmake/hip/FindHIP.cmake`, but horovod's
   `horovod/common/ops/rocm/CMakeLists.txt` has a typo (`HCC_APTH`) that
   leaves `HIP_PATH` unset, so `find_package(HIP)` falls through to the
   modern `hip-config.cmake` which omits the macro. The build aborts with
   `Unknown CMake command 'hip_add_library'`.  
   **Patched file**: [`rocm__CMakeLists.txt`](rocm__CMakeLists.txt) —
   point `CMAKE_MODULE_PATH` at the actual `FindHIP.cmake` location and
   `include(FindHIP)` explicitly. Drop in at
   `horovod-0.28.1/horovod/common/ops/rocm/CMakeLists.txt`.

4. **`rccl.h: No such file or directory`**. ROCm 6.0's
   `rccl-config.cmake` exports `RCCL_INCLUDE_DIRS=$ROCM/include` but the
   header lives at `$ROCM/include/rccl/rccl.h`, and horovod's
   `nccl_operations.h` does `#include <rccl.h>` (no `rccl/` prefix).  
   **Patched file**: [`top_CMakeLists.txt`](top_CMakeLists.txt) — after
   `find_package(rccl)`, also `include_directories(SYSTEM
   $ROCM/include/rccl)` if the header is present there. Drop in at
   `horovod-0.28.1/CMakeLists.txt`.

5. **`pip install .` tries to copy a non-existent torch shared library**
   even with `HOROVOD_WITHOUT_PYTORCH=1`. The wheel build itself
   succeeds (tensorflow `.so` is produced), but the install step fails
   afterwards.  
   Workaround in [`rebuild_horovod.sh`](rebuild_horovod.sh): run
   `python setup.py build_ext --inplace` to build, then rsync the
   `horovod/` python tree + the built
   `horovod/tensorflow/mpi_lib.cpython-310-x86_64-linux-gnu.so` directly
   into the env's `site-packages`, plus the generated `metadata.json`.

## Verification

After the rebuild:

```python
import horovod.tensorflow as hvd
print('nccl_built ', hvd.nccl_built())   # expect non-zero (e.g. 21803 = RCCL 2.18.03)
print('rocm_built ', hvd.rocm_built())   # expect True
print('mpi_built  ', hvd.mpi_built())    # expect True
print('gloo_built ', hvd.gloo_built())   # expect True
print('cuda_built ', hvd.cuda_built())   # expect False (this is the ROCm build)
```

`ldd $envpath/horovod/tensorflow/mpi_lib*.so` should mention
`librccl.so.1`, `libamdhip64.so.6`, `libmpi_cray.so.12`.

## Use

```bash
bash scripts/env/horovod_rocm_patches/rebuild_horovod.sh
```

This:
1. Module-loads `PrgEnv-gnu cmake/3.27.9 rocm/6.0.0 cray-mpich/8.1.31 craype-accel-amd-gfx90a gcc-native/13.2`.
2. Sets the `HOROVOD_*` env so the build picks RCCL + ROCm.
3. Runs `python setup.py build_ext --inplace` then rsyncs the result
   into `/ccs/home/ghu4/envs/cosmoflow_rocm/lib/python3.10/site-packages/horovod/`.
4. Verifies `nccl_built` / `rocm_built` via a one-liner.

Before running, copy the two patched CMakeLists into your horovod source
tree:

```bash
cp rocm__CMakeLists.txt /path/to/horovod-0.28.1/horovod/common/ops/rocm/CMakeLists.txt
cp top_CMakeLists.txt  /path/to/horovod-0.28.1/CMakeLists.txt
```

(Or apply the unified diff if you prefer a `git apply`-style flow — the
two files are the only changes.)
