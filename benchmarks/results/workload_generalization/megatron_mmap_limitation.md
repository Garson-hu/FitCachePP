# mmap-based workloads (Megatron-LM AND DINOv2) are incompatible with LD_PRELOAD-style I/O interception

**Date:** 2026-05-12
**Finding:** Megatron-LM's `IndexedDataset` uses `numpy.memmap` to access the tokenized `.bin` blob. Subsequent token reads via `dataset.get(doc_idx, length=N)` are **memory page faults**, not `read()` syscalls. FitCache's LD_PRELOAD client intercepts `open()`, `read()`, `pread()`, `lseek()`, `fopen()`, `close()` — but not `mmap()` page faults. Megatron training data therefore **bypasses FitCache entirely**, independent of any FitCache_DATA_DIR configuration.

## Evidence

Source: [`megatron/core/datasets/indexed_dataset.py:280`](/home/ghu4/hvac/benchmark/Megatron-LM/megatron/core/datasets/indexed_dataset.py#L280)
```python
self.bin_buffer_mmap = numpy.memmap(idx_path, mode="r", order="C")
self.bin_buffer = memoryview(self.bin_buffer_mmap)
```
And again at line 402 for the .bin file. Every Megatron training step calls `dataset.get(...)` which returns slices of `bin_buffer`. These are page faults on the mmap'd region — the kernel reads from disk into the page cache via the storage stack, but the LD_PRELOAD'd library never sees the access.

Empirical confirmation (this session, [megatron_io_only_iter.py](../../benchmarks/megatron/megatron_io_only_iter.py)):
- 200 iters × 4 samples × 1024 tokens = 819,200 token requests
- Wall-clock: ~0.00s (i.e. < 5ms total, dominated by Python interpreter startup)
- 45,000 iters/s on a 5.9 MiB .bin file = pure memory access speed
- For comparison, running this through LD_PRELOAD=libfitcache_client.so produces identical wall-clock and zero Open RPC traffic in any FitCache server log

## Additional finding: DINOv2 has the same architectural issue

DINOv2's `ImageNet22k` class also uses mmap. From [`dinov2/data/datasets/image_net_22k.py`](/home/ghu4/hvac/benchmark/dinov2/dinov2/data/datasets/image_net_22k.py):
```python
from mmap import ACCESS_READ, mmap
...
def _mmap_tarball(class_id: str) -> mmap:
    ...
    return mmap(fileno=f.fileno(), length=0, access=ACCESS_READ)
...
class_mmap = self._mmap_tarball(class_id)
...
mapped_data = class_mmap[start_offset:end_offset]
```
Plus `np.load(extra_full_path, mmap_mode="r")` for the metadata. So DINOv2 mmaps each per-class .tar file once, then slices into the mmap for individual image extraction. Same architectural pattern as Megatron — no syscall traffic for individual image reads.

## Implication for the TPDS workload-generalization claim

**Both targeted workloads** (Megatron-LM and DINOv2) use mmap-based I/O. The workload-generalization eval as originally planned in `tpds_extension/04_experiment_plan.md` §IV-H cannot be defended with the current FitCache architecture. Options:

1. **Drop Megatron + DINOv2 from the workload-generalization eval.** Pick alternative workloads that use syscall-based I/O: HuggingFace `datasets` with `streaming=True` (uses iterative open/read); ResNet50 on ImageNet via PIL.Image.open on individual .jpeg files (not tar-bundled); raw text dataloaders.

2. **Add an mmap interceptor to libfitcache_client.so** (substantial design work). Intercept `mmap`/`mmap64` for paths matching `FitCache_DATA_DIR`, return a userspace-managed buffer backed by the FitCache cache. Conceptually similar to how MS_READ handled bulk transfers, but at the mmap layer. Several weeks of work; not in this session's scope.

3. **Document the architectural limitation** and frame the FitCache contract precisely: "FitCache++ accelerates workloads with syscall-based I/O (open/read/pread). Workloads using mmap-based zero-copy I/O (such as Megatron-LM's `IndexedDataset` and DINOv2's tarball-mmap loader) require an additional mmap-interception layer outside the LD_PRELOAD scope."

Option 3 is the honest framing for the paper.

## What we already have for the workload-generalization runs

- Synthetic tokenized corpus prepared: `/mnt/beegfs/ghu4/hvac/megatron_pile_train_001/pile_slice_text_document_text_document.{bin,idx}` (5.9 MB + 977 KB).
- GPT2 tokenizer assets cached: `/mnt/beegfs/ghu4/hvac/megatron_assets/gpt2-{vocab.json,merges.txt}`.
- `dpu_torch` conda env with PyTorch 2.5.1 + nltk + einops + omegaconf — Megatron's preprocess pipeline works (we ran it to make the .bin/.idx).
- I/O-only iterator script in `benchmarks/megatron/megatron_io_only_iter.py` — useful for testing access patterns when/if mmap interception is added.

These artifacts remain useful for follow-up work on option 2 (mmap interceptor) or for testing alternative LLM workloads under option 1.
