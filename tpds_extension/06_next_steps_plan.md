# TPDS extension — next-steps plan with experiments and results

**Date:** 2026-05-11
**Audience:** the user, after reviewing the IPDPS experiment structure at
`/home/ghu4/hvac/benchmark/cosmoflow-benchmark-master/`.

## What the IPDPS paper measured (recap, learned from `PDSW_Exps.sh` + `logs/pdsw/`)

| Dimension | IPDPS values |
|---|---|
| Systems compared | **Pure_CF** (no cache, direct BeeGFS) → **HVAC** (single-job cache) → **FitCache** (improved single-job cache) |
| GPU sweep | 1, 2, 4, 8, 16 GPUs |
| Dataset | `cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440` (`n_train=61440`, FULL 61k-sample dataset — 60× larger than the `train_1024` mini I've been using) |
| Server topology | 8 servers split across 1-2 PMem nodes (c35/c36 with `/mnt/fsdax/ghu4/train_cache`) |
| Tier sizes | 400 GiB FSDAX (PMem) + 500 GiB SSD |
| Result format | `logs/pdsw/RunTime{1,2,3}/<system>-<jobid>_<N>GPUs_<dataset>.out` — 3 repeated runs of every (system × GPU-count) cell, log scrubbed for `Mean epoch time` |

The IPDPS contribution is the **GPU-scaling story** (FitCache stays competitive with Pure_CF as GPUs scale, where the I/O bottleneck would normally dominate) and the **two-tier extrapolation** (FSDAX + SSD vs SSD-only).

## What TPDS adds (from `tpds_extension/00_PLAN.md` + `04_experiment_plan.md`)

Four new dimensions on top of the IPDPS baseline:

1. **Cross-job sharing** — 2 concurrent jobs, 2 sequential jobs (not exercised in IPDPS).
2. **Three-tier** — DRAM + PMem + NVMe (IPDPS was effectively two-tier: PMem + NVMe).
3. **Workload generalization** — Megatron-LM (LLM) and DINOv2 (image SSL) — IPDPS only ran CosmoFlow + DeepCAM.
4. **Sensitivity / failure-injection** — what happens under server churn, registry GC pressure, peer-fail recovery (deferred to a separate experiment block).

## Where we are right now (results in hand)

| Item | Status | Notes |
|---|---|---|
| FitCachePP single-job baseline (1 GPU, c66, `train_61440` path, `n_train=1024` subset) | **In progress** as SLURM 221634 | Cold epoch 216s, warm 202-203s; **down from 385s on the broken 221630 run** thanks to the data-mover signal-loss fix |
| Bit-equivalence smoke (synthetic 8 files) | **PASS** | byte-identical cache content for `CROSS_JOB={0,1}` |
| Three-tier local smoke (synthetic 12 files, 3 tiers) | **PASS** | 4/4/4 placement + full per-tier sidecar restore on restart |
| Two-server peer-lookup localhost smoke | **PASS** | 4 redirects fired |
| Megatron access-pattern smoke (synthetic `.bin` + `.idx`) | **PASS** | both files cached + sidecars + sha256 match |
| DINOv2 access-pattern smoke (synthetic 4 classes × 10 imgs + metadata) | **PASS** | 42/42 cached + 42/42 sidecars |
| Cluster two-job concurrent (real CosmoFlow) | **REGRESSED** — needs P0-3 re-run with all the bug fixes | Prior runs (221614/615/616/617) had FitCache *not engaged* (path-filter mismatch + signal-loss bug); the 200s/188s numbers in `summary_221614_221615.md` are kernel-page-cache, not FitCache |
| Cluster two-job sequential (real CosmoFlow) | **REGRESSED** — needs P0-4 re-run | Same root cause; `summary_221618_221619.md` documents this |
| Three-tier on real PMem (c35) | **BLOCKED on sysadmin** | c35 has the hardware but `/dev/pmem0` is not currently mounted; no GPU+PMem node exists on cluster |
| Megatron-LM real cluster run | **NEEDS USER PREP** | Need conda env + tokenized corpus + tokenizer files |
| DINOv2 real cluster run | **NEEDS USER PREP** | Need conda env + ImageNet-22k images + entries.txt/class_ids.txt |

## Plan for next steps, ordered by what produces results fastest

### Phase A — Defend the IPDPS baseline at FitCachePP parity (1 GPU, c66, full dataset)

**Goal:** show FitCachePP's single-job behavior matches FitCache's IPDPS numbers.
**Apples-to-apples comparison:** same node (c66), same dataset (`train_61440`),
same n_train (the full 61440 — IPDPS's value, not the mini's 1024).

Concrete actions:

1. Update `PDSW_FITPP.sh` to pass `--n-train 61440` to `train.py` (currently the YAML default of 1024 is used — that's why our cold/warm gap is small). One-line change.
2. Re-submit single-job baseline 3 times with `--n-train 61440` and average. Compare `Mean epoch time` to the IPDPS `logs/pdsw/RunTime{1,2,3}/FitCache-*.out` numbers.
3. Repeat for `Pure_CF` (FitCache OFF — set `FitCache_CROSS_JOB=0` AND `LD_PRELOAD` empty / not set so we measure raw BeeGFS read).
4. **Result file:** `benchmarks/results/single_job_baseline/summary_phase_A.md` with three columns (Pure_CF / IPDPS_FitCache / FitCachePP) and per-epoch numbers.

**Estimated wall-clock at full dataset (60× the train_1024 numbers):** each run ~60×16min ≈ 16 hours per run. 3 runs × 3 systems = 27 jobs at ~16h = too slow on a single node.

**Realistic alternative:** use `--n-train 8192` (or 16384) — still a 8-16× scale-up from the mini, but jobs finish in ~2-4 hours so we can do 3 runs of each system in a day. The IPDPS already published the absolute n_train=61440 numbers; for the TPDS comparison we need the *relative* gap (Pure vs FitCachePP), and that scales linearly with n_train.

### Phase B — Cross-job sharing experiments (the headline new contribution)

**Goal:** defend the cross-job-sharing-reduces-aggregate-IO claim.

1. **Two-job concurrent on c70 + c71.** With the addr-in-hash HRW fix from earlier today, routing now distributes across the two cloned-machine-id nodes. Submit `PDSW_FITPP_two_job_concurrent.sh` 3 times. Verify in each run that `cross_job_stats` shows `peer_lookup_forwarded > 0` and `opens_redirect_to_peer > 0` — direct evidence the cross-job pathway fired (NOT just kernel page cache).
2. **Two-job sequential on c66.** Job A runs, exits, job B starts on the same node and rebuilds path_cache_map from sidecars. Verify Job B epoch-1 ≈ Job A epoch-2 (warm), not Job A epoch-1 (cold).
3. **Result files:** `summary_phase_B_concurrent.md` and `summary_phase_B_sequential.md`. Tables with cold/warm epoch times AND the cross_job_stats counter dumps proving FitCache engaged.

**Wall-clock:** each run ~30-60 min depending on n_train. 3 concurrent + 3 sequential = ~6 hours total assuming nodes are available.

### Phase C — Workload generalization (Megatron-LM + DINOv2)

**Goal:** defend "FitCache++ generalizes beyond CosmoFlow/DeepCAM" claim.

What's already in place: the access-pattern smokes both PASS, which proves the FitCache code paths handle the I/O shapes correctly. What's needed for the full claim is the actual model running.

**Megatron path (~1-2 days of user setup, then experiments):**
1. User: install PyTorch + apex + Megatron's deps in a conda env at `/home/ghu4/hvac/rlibrary/miniconda3/envs/megatron/`.
2. User: download `gpt2-vocab.json` + `gpt2-merges.txt`.
3. User: run `Megatron-LM/tools/preprocess_data.py` over a small corpus (e.g. 1 GB of WikiText) to produce `<prefix>.bin` + `<prefix>.idx` under `/mnt/beegfs/ghu4/hvac/megatron_pile_train_001/`.
4. Submit `benchmarks/megatron/PDSW_FITPP_megatron.sh` — runs a 12-layer GPT for 1000 iters. Compare to a no-FitCache baseline (run with `LD_PRELOAD` unset).
5. **Result:** `summary_phase_C_megatron.md` showing iters/sec with vs without FitCache.

**DINOv2 path (~2-3 days of user setup, then experiments):**
1. User: install PyTorch + DINOv2's pip deps in `/home/ghu4/hvac/rlibrary/miniconda3/envs/dinov2/`.
2. User: download a small ImageNet subset (or use the existing `train_5120` cosmo data as a substitute for the file-count shape; doesn't have to be ImageNet specifically).
3. User: generate the `entries.txt` / `class_ids.txt` metadata via DINOv2's prep script.
4. Submit `benchmarks/dinov2/PDSW_FITPP_dinov2.sh` for 1 epoch. Compare with vs without FitCache.
5. **Result:** `summary_phase_C_dinov2.md` showing per-step time + cross_job_stats counters.

### Phase D — Three-tier on real PMem hardware (blocked-on-sysadmin)

**Goal:** defend the IPDPS two-tier-extrapolation experiment with REAL three-tier numbers.

1. User/sysadmin: `mount -o dax /dev/pmem0 /mnt/pmem` on c35 (one-time root operation).
2. Submit `scripts/run_three_tier_sustained_read.sh` on c35 with `PMEM_PATH=/mnt/pmem/ghu4/fitcachepp_three_tier_pmem`. 256 files × 4 MiB = 1 GiB working set.
3. **Result:** `summary_phase_D_three_tier.md` showing warm-vs-cold ratio with vs without PMem tier enabled.

Constraint: c35 has no GPU, so CosmoFlow + Horovod can't run there. The sustained-read measurement is the substitute for the GPU-CosmoFlow run that IPDPS would have done. Acceptable for the TPDS three-tier claim because the *placement and eviction* paths are what we're measuring, not GPU-coupled performance.

### Phase E — Sensitivity / ablation / failure injection (the smallest TPDS chunk)

Per `04_experiment_plan.md` §IV-K. Lower priority; do after A-D.

1. **Server-set churn:** start 4 servers, kill one mid-run, verify the live set reconverges and routing rebalances (HRW remap). Localhost smoke that drives this is straightforward — just a variant of `run_two_server_smoke.sh`.
2. **Registry GC under load:** verify the rmw fix from today (commit `0602e71`) keeps the registry stable when N concurrent heartbeats race.
3. **Failure injection:** (deferred to Frontier-scale evaluation per the experiment plan).

## Recommended execution order for the next 1-2 days

| Day | Phase | Wall-clock cost | What we get |
|---|---|---|---|
| Today (rest of session) | Phase A.1: update `--n-train` flag + submit ONE single-job baseline at `n_train=8192` for c66 to compare cold/warm vs current `n_train=1024` numbers | ~30-60 min | Real "FitCache engaged at scale" data point |
| Tomorrow morning | Phase A.2-3: 3 runs each of Pure_CF + FitCachePP at `n_train=8192` on c66 | ~6 hours | Phase A summary table |
| Tomorrow afternoon | Phase B.1: 3 runs of two-job concurrent on c70+c71 at `n_train=8192` | ~3-4 hours | Phase B concurrent table |
| Tomorrow evening | Phase B.2: 3 runs of two-job sequential on c66 at `n_train=8192` | ~3-4 hours | Phase B sequential table |
| Day 3+ | Phase C and D as user dataset prep allows | varies | |

## What I'm doing right now

While writing this plan, **SLURM 221634 is in flight** — single-job baseline on c66 at `n_train=1024` (the train.py YAML default) with the data-mover bug fixed. Currently 12 minutes in, on epoch 4 of 5. Expected to complete around 07:30. **First numbers I can report:**

```
221634 (FitCachePP, c66, 1 GPU, n_train=1024, with data-mover fix):
  epoch 1 (cold): 216s
  epoch 2:        202s
  epoch 3:        203s
  epoch 4:        in progress
  epoch 5:        pending
```

For comparison, the IPDPS-published FitCache numbers from
`logs/pdsw/RunTime1/FitCache-135913_1GPU_61440.out` use `n_train=61440`,
so wall-clock comparison isn't apples-to-apples. The Phase A.1 step
above is the fix.
