# Workload-generalization runs — setup and run guide

**Date:** 2026-05-11
**Goal:** Defend the workload-generalization claim in
`tpds_extension/04_experiment_plan.md` §IV-H — i.e. show FitCache++
accelerates non-CosmoFlow workloads with different I/O shapes:

| Workload     | Access shape                                       | What FitCache does |
|--------------|----------------------------------------------------|--------------------|
| Megatron-LM  | Large sequential streaming over `.bin` + `.idx`    | Promote both into a tier; subsequent epochs read from cache |
| DINOv2       | Small files (`~100 KB` images) in a deep tree      | Promote individual images on first read; subsequent epochs hit cache |

## What is already in place

- **Megatron-LM source** at [/home/ghu4/hvac/benchmark/Megatron-LM/](/home/ghu4/hvac/benchmark/Megatron-LM/) (shallow clone, ~64 MB, source code only).
- **DINOv2 source** at [/home/ghu4/hvac/benchmark/dinov2/](/home/ghu4/hvac/benchmark/dinov2/) (shallow clone, ~6.9 MB, source code only).
- **Access-pattern smokes** that prove FitCache catches each workload's I/O shape on synthetic data, without needing the real models or datasets:
  - [scripts/smoke/run_megatron_access_pattern_smoke.sh](../../scripts/smoke/run_megatron_access_pattern_smoke.sh) — `.bin` + `.idx` pair. PASS as of commit `c6c25ee` (the data-mover signal-loss fix made the 2-file case work).
  - [scripts/smoke/run_dinov2_access_pattern_smoke.sh](../../scripts/smoke/run_dinov2_access_pattern_smoke.sh) — 4 classes × 10 images + 2 metadata files. PASS — 42/42 cached + 42/42 sidecars + sha256 match.
- **Cluster sbatch templates** that wire each model's training command through `LD_PRELOAD=libfitcache_client.so`:
  - [benchmarks/megatron/TPDS_FITPP_megatron.sh](../../benchmarks/megatron/TPDS_FITPP_megatron.sh) + [command_megatron_FITPP.sh](../../benchmarks/megatron/command_megatron_FITPP.sh)
  - [benchmarks/dinov2/TPDS_FITPP_dinov2.sh](../../benchmarks/dinov2/TPDS_FITPP_dinov2.sh) + [command_dinov2_FITPP.sh](../../benchmarks/dinov2/command_dinov2_FITPP.sh)
- **`TPDS_FITPP_inner.sh`** now honors `FITCACHE_CLIENT_LAUNCHER` so the same launcher serves CosmoFlow, Megatron, and DINOv2 — no fork.

## What the user still needs to do before submission

### Megatron-LM

1. **Conda env with PyTorch + apex + Megatron's deps.** Create at
   `/home/ghu4/hvac/rlibrary/miniconda3/envs/megatron/`. Megatron requires
   apex's fused kernels (`pip install nvidia-apex` will not work; build
   from source with `--cuda_ext --cpp_ext`). Adjust `MEGATRON_PYTHON` in
   `TPDS_FITPP_megatron.sh` if you put it elsewhere.
2. **Tokenizer assets.** Download `gpt2-vocab.json` + `gpt2-merges.txt`
   from HuggingFace and place under
   `/mnt/beegfs/ghu4/hvac/megatron_assets/`. Adjust
   `MEGATRON_VOCAB_FILE` + `MEGATRON_MERGE_FILE` if elsewhere.
3. **Tokenized corpus.** Run Megatron's
   `tools/preprocess_data.py` over your text corpus to produce the
   paired `<prefix>.bin` + `<prefix>.idx`. Put under
   `/mnt/beegfs/ghu4/hvac/megatron_pile_train_001/` and set
   `MEGATRON_DATA_PREFIX=/mnt/beegfs/ghu4/hvac/megatron_pile_train_001/pile_slice_text_document`
   (note: `text_document` is the prefix, Megatron appends `.bin`/`.idx`).
4. **Submit:**
   ```bash
   sbatch /home/ghu4/hvac/FitCachePP/benchmarks/megatron/TPDS_FITPP_megatron.sh
   ```

### DINOv2

1. **Conda env with PyTorch + DINOv2's pip deps.** Create at
   `/home/ghu4/hvac/rlibrary/miniconda3/envs/dinov2/`.
2. **ImageNet-22k images.** Place under `DINOV2_DATASET_ROOT`
   (default `/mnt/beegfs/ghu4/hvac/imagenet22k`). Expected layout:
   ```
   imagenet22k/
     n01001234/img_00000001.jpg ... img_00001300.jpg
     n02002345/...
     ... 21841 classes total
   ```
3. **Metadata.** Run DINOv2's
   `dinov2/data/datasets/image_net_22k.py` (or follow the repo's
   "Data preparation" README section) to produce `entries.txt` and
   `class_ids.txt`. These should land under `DINOV2_EXTRA_DIR`
   (default `/mnt/beegfs/ghu4/hvac/imagenet22k_extra`).
4. **Config.** Create a YAML config under
   `benchmarks/dinov2/configs/` (template can be copied from
   `dinov2/dinov2/configs/train/vitl16_short.yaml` and reduced to
   ViT-S/14 for a smoke run). Adjust `DINOV2_CONFIG` to point at it.
5. **Submit:**
   ```bash
   sbatch /home/ghu4/hvac/FitCachePP/benchmarks/dinov2/TPDS_FITPP_dinov2.sh
   ```

## What the runs will defend

For each workload, the relevant claim from `04_experiment_plan.md` §IV-H:

- **Cold-vs-warm epoch reduction.** Epoch 1 reads from BeeGFS + populates
  cache; epoch 2+ reads from local NVMe/DRAM. The reduction should be
  comparable to CosmoFlow's (the IPDPS claim was ~2× for the
  comparable read-bound workload shape).
- **Cross-job sharing.** Two concurrent Megatron jobs reading the same
  tokenized corpus get cross-cache hits via the HRW + peer-lookup
  redirect path. Run `TPDS_FITPP_megatron.sh` twice with different
  `SLURM_JOBID` against the same `FitCache_CLUSTER_REGISTRY_DIR` — the
  second job's epoch-1 should hit the first's cache.
- **Workload-shape robustness.** The Megatron `.bin`/`.idx` shape
  (large-streaming) and the DINOv2 small-files-deep-tree shape are
  both correctly handled by the same FitCache code paths — defending
  the "not CosmoFlow-specific" claim.

## What to verify after each run

The engagement self-check at the end of `TPDS_FITPP_inner.sh` already
prints either:
```
FitCache engaged: <N> Open RPCs handled across all servers; <M> files cached.
```
or
```
!!! WARNING !!! No FitCache engagement signal: zero Open RPC log lines
AND zero cached files in DRAM/NVMe/PMem tier dirs.
```
If the warning fires, FitCache_DATA_DIR or the training-script
`--data-dir`/config doesn't match the actual data path. Compare
`FitCache_DATA_DIR` against the resolved `data_path` printed by the
training script's startup log.
