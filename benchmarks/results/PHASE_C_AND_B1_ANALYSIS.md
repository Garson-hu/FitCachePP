# Phase C (workload generalization) + Phase B.1 deeper analysis

**Date:** 2026-05-12
**Status:** two architectural-limit findings landed this session; both require follow-up code work beyond the LD_PRELOAD intercept layer.

## Finding 1 — Phase C: Megatron-LM AND DINOv2 both use mmap, bypassing LD_PRELOAD

Both target workloads for the TPDS workload-generalization eval use memory-mapped I/O:

- **Megatron-LM** (`megatron/core/datasets/indexed_dataset.py:280`): `numpy.memmap(idx_path, mode="r")` for the .idx and again for the .bin. Each training step calls `dataset.get(doc_idx, length=N)` which returns slices of the mmap'd memoryview. Token reads are **page faults**, not `read()` syscalls.

- **DINOv2** (`dinov2/data/datasets/image_net_22k.py:65`): `mmap(fileno=f.fileno(), length=0, access=ACCESS_READ)` for each per-class .tar bundle. `mapped_data = class_mmap[start_offset:end_offset]` is again a page-faulted byte-slice, not `read()`.

FitCache's LD_PRELOAD client (`libfitcache_client.so`) intercepts `open`, `open64`, `read`, `pread`, `lseek`, `fopen`, `fopen64`, `close`, `fsync`, `fclose` — **but not `mmap`**. So when Megatron/DINOv2 access their data via memory slicing, FitCache sees zero traffic.

**Empirical confirmation:** ran `megatron_io_only_iter.py` (uses Megatron's `IndexedDataset` to issue the same `get()` calls a real training step would) — 200 iters in < 5ms (~45k iters/s, pure memory speed). With or without `LD_PRELOAD=libfitcache_client.so`, behavior is identical and FitCache server logs show 0 Open RPC.

### Options for the paper

1. **Drop Megatron + DINOv2** from the workload-generalization eval. Replace with syscall-based workloads:
   - HuggingFace `datasets.load_dataset(..., streaming=True)` — iterates files via standard read.
   - ResNet50 on ImageNet using per-file PIL.Image.open (not tar-bundled).
   - Raw text classification with line-by-line readers.

2. **Add an `mmap` interceptor** to libfitcache_client.so. For paths matching `FitCache_DATA_DIR`, replace `mmap` with a userspace buffer backed by the FitCache cache; intercept the resulting page faults via `userfaultfd`. Substantial work (weeks); not in this session.

3. **Re-frame the FitCache contract**: "FitCache++ accelerates workloads with syscall-based I/O (open/read/pread). Workloads using mmap-based zero-copy I/O require an additional mmap-interception layer outside the LD_PRELOAD scope. Megatron-LM and DINOv2 fall in this category; their integration is future work."

Option 3 is the honest framing. CosmoFlow (TFRecordDataset) uses standard reads so the IPDPS evaluation is unaffected. The workload-generalization claim narrows to "syscall-based workloads beyond CosmoFlow/DeepCAM."

### Phase C artifacts that remain useful

- Synthetic tokenized corpus: `/mnt/beegfs/ghu4/hvac/megatron_pile_train_001/pile_slice_text_document_text_document.{bin,idx}` (5.9 MB + 977 KB).
- GPT2 tokenizer: `/mnt/beegfs/ghu4/hvac/megatron_assets/gpt2-{vocab.json,merges.txt}`.
- `dpu_torch` conda env with PyTorch 2.5.1 + nltk + einops + omegaconf + transformers.
- I/O-only iterator script: `benchmarks/megatron/megatron_io_only_iter.py`.
- Access-pattern smokes (use harness_read_files with read syscalls — these PASS but exercise FitCache's path-filter, NOT the actual Megatron/DINOv2 mmap path).

## Finding 2 — Phase B.1: HRW imbalance + per-server path_cache_map partitioning

The seed-divergence fix (FITPP_SEED=1 vs 2) was correct for the same-order-race issue identified earlier, but Phase B.1 retry still shows `has_yes=0 / opens_redirect_to_peer=0` after 14 minutes of runtime. Per-rank cross_job_stats reveals the deeper cause:

| Job | rank=0 opens | rank=1 opens | rank=2 opens | rank=3 opens | Total | has_yes |
|---|---:|---:|---:|---:|---:|---:|
| Job A (c66) | **0** | **0** | 164 | 219 | 383 | 0 |
| Job B (c67) | **0** | 5,511 | 4,895 | **0** | 10,406 | 0 |

Two issues compound:

1. **HRW is concentrating opens on a subset of servers.** Out of 4 servers per job (8 total in the cluster registry), only 2 per job receive non-zero traffic. This isn't fundamental HRW behaviour — with FNV-based hashing across 8 servers, you'd expect ~12.5% load each. Possible cause: the cluster `registry_live_servers()` snapshot is dropping some servers as "stale" depending on when it's sampled relative to heartbeat. The 5-second snapshot TTL + jittered heartbeat could give different live-set views to different processes.

2. **path_cache_map is per-server-process.** Job A's rank=2 caches its files locally to that process. When Job B's open handler does peer_lookup, the HRW pick may route the question to Job A's rank=0 or rank=1 (which received 0 opens, have empty path_cache_map) instead of rank=2 or rank=3 (which have the cache). The responder honestly says "no" because it doesn't have the file — but a sibling server in the same job DOES.

### What this would take to fix

The fix is one of:

a) **Forward peer_lookup to ALL sibling servers on the responding node** (broadcast within the node, return has_yes if ANY of them has the file). This is the cleanest semantic — path_cache_map at the JOB granularity, not the server-process granularity.

b) **Share path_cache_map across server processes on the same node** via SHM or a single-server-per-node design. Bigger refactor.

c) **Fix HRW imbalance so opens are evenly distributed across all 4 servers per job**, eliminating the "empty rank" subset. Investigate why HRW is picking only 2 of 8 servers.

Option (a) is the smallest, most localized change. Add a sibling-fanout to `fitcache_peer_lookup_rpc_handler` that queries the other 3 servers on the same host before answering has_no.

## Combined status for the TPDS submission

| Claim | Status this session |
|---|---|
| Zero-regression-vs-IPDPS-single-job | ✅ defended (Phase A + bit-equivalence smoke) |
| Single-job FitCache+CosmoFlow at multi-node scale | ✅ defended (Phase A first run 221645 with 46k Open RPCs, 9216 cached files) |
| Cross-job sidecar restore | ✅ defended (Phase B.2: Job B saved 44s via 9216-file sidecar restore) |
| Cross-job concurrent peer_lookup redirect | ⚠️ HRW imbalance + per-server path_cache_map issue; needs fix (a) above |
| Workload generalization (Megatron + DINOv2) | ❌ both use mmap; need mmap interceptor OR different workloads |
| Three-tier on real PMem (c35 /mnt/fsdax) | 🚧 blocked on sysadmin write access |

The two ⚠️/❌ items are the open follow-ups. Phase B.1's fix (sibling-fanout in peer_lookup_handler) is ~50 LOC + a smoke test — small, scoped. The workload-generalization story needs a strategy decision: pick syscall-based workloads, or build the mmap interceptor (substantial).
