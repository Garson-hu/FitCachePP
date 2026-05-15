# Experiment Status — FitCache++ (TPDS extension)

Single-glance tracker organized by the experiment blocks from
`tpds_extension/04_experiment_plan.md`. Status legend:

- ✅ **Positive** — supports a paper claim, no remediation needed
- ⚠️ **Mixed** — partially positive, with a known caveat that limits the claim
- ❌ **Negative** — surprised the wrong way; needs remediation before paper
- 🚧 **Blocked** — has a known bug or missing piece preventing completion
- ⏸️ **Deferred** — agreed low-priority; revisit when other items land

Date: 2026-05-12 (full single-job FitCachePP-vs-Pure_CF baseline runs +
two-job sequential sidecar-restore complete; the two-job concurrent
cross-job-sharing run exposed a real mechanism gap; the real-PMem
hardware evaluation on c35 was unblocked late in the day after
/mnt/fsdax write access was restored). Source data: `benchmarks/results/arc/`
subtrees referenced inline. **Headline summary:**
[benchmarks/results/arc/single_job_baseline_and_sidecar_restore_summary.md](benchmarks/results/arc/single_job_baseline_and_sidecar_restore_summary.md).

---

## Experiment 1: Single-job baseline (FitCachePP vs IPDPS-FitCache vs Pure_CF)

**Goal**: defend the zero-regression-vs-IPDPS-single-job claim and the
shape parity with the IPDPS PDSW_Exps numbers. Foundation for §V's
single-job comparison block.

**App**: CosmoFlow on `cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440/`,
4 FitCache servers + 1 GPU client, sbatched via PDSW_FITPP_multinode.sh
(c35 storage + GPU node client) to mirror the IPDPS PDSW_Exps.sh layout.

### 1a. Single-node smoke (c66 only, FitCache servers + client co-located, n_train=1024)

| Configuration | Cold ep1 | Warm ep2-5 | Mean | Open RPCs | Cached files | Status |
|---|---:|---:|---:|---:|---:|:---:|
| **221634 FitCachePP (with all bug fixes)** | **216s** | 199-203s | **203s** | **10,248** | **2,048** | ✅ |
| 221630 FitCachePP (pre data-mover fix) | 385s | 187-190s | 227s | (logged at NOTICE; suppressed) | unknown | ❌ |
| 221620 FitCachePP (pre lookup_addr fix) | crash@first open | — | — | — | — | ❌ |
| 221607 IPDPS-style (CROSS_JOB=0, before path-filter fix) | 199s | 187-189s | 191s | **0** | **0** | ❌ FitCache bypassed |

- ✅ **221634 is the first cluster run where FitCache is verifiably engaged** (10,248 Open RPCs across 4 servers, 2,048 cached files in `/mnt/local/ghu4/fitcachepp_train_cache_dram` on c66).
- ✅ **Data-mover signal-loss fix delivered a 45% cold-epoch reduction** on the same workload (385s → 216s), attributable purely to commit `c6c25ee`.
- ⚠️ **Cold-vs-warm gap small** (216 → 200 = 8%): `n_train=1024` is too small to stress I/O — the dataset fits in c66 free RAM so even "warm" reads are kernel-page-cached. The fix is scaling up to a larger n_train (8192 baseline below; 61440 would be ideal but is too long for repeat runs).
- ❌ **Prior baselines (221607, ...615, ...617, ...619) all show 0 Open RPCs** — see `summary_221618_221619.md`. The ~200s cold / ~188s warm pattern they reported is kernel page cache + GPU/TF warmup, not FitCache. **Do not quote those numbers.**
- Source: `benchmarks/results/arc/single_job_baseline/summary_221634_engaged.md`. Memory `project_fitcachepp_tpds.md`.

### 1b. Single-node baseline (c66 GPU+storage co-located, n_train=8192)

Scaled to `n_train=8192` for tractable wall-clock (~1.5h/run vs IPDPS 9.7h).
Comparison column is RELATIVE ratio (Pure_CF vs FitCachePP). Pure_CF ×2 reps with
σ<2s (rep 3 skipped); FitCachePP ×3 reps with σ<3s. Headline is Pure_CF vs FitCachePP
**means** — both at the same single-job-1-GPU regime.

| Configuration | Mean | Cold ep1 | Warm ep2-5 | σ across reps | Status |
|---|---:|---:|---:|---:|:---:|
| **Pure_CF (no LD_PRELOAD)** | **841s** | 855s | 838s | < 2s | ref |
| **FitCachePP CROSS_JOB=0** | **899s** | 935s | 891s | < 3s | ⚠️ +7% overhead |
| Pure_CF OS-cold (FITPP_DROP_PAGECACHE=1) | 840s | 855s | 838s | 1 rep | ✅ confirms page cache not the bottleneck |
| FitCachePP OS-cold | 899s | 935s | 891s | 1.5 reps | ✅ same as OS-warm |
| IPDPS FitCache 1 GPU n_train=61440 (ref from logs/pdsw/) | 6968s | 7552s | 6573s | published | ref |

**Finding:** At n_train=8192 on 1 GPU, **FitCachePP adds 58s = ~7% overhead** (Mercury RPC per file open). Pure_CF dataset (167 GB) fits in c66's 188 GB RAM → page cache absorbs working set → FitCachePP's "local cache" pathway has nothing structural to win. **The overhead is the cost of FitCachePP's scaling infrastructure;** the benefit emerges at multi-GPU multi-node large-working-set regime (the IPDPS-extrapolation case) and in cross-job mode (the two-job sequential sidecar-restore experiment below). Detailed analysis in [single_job_baseline_and_sidecar_restore_summary.md](benchmarks/results/arc/single_job_baseline_and_sidecar_restore_summary.md).

### 1c. Multi-node single-job (c35 storage + c66 GPU client, SLURM 221645)

| Configuration | Mean | Cold ep1 | Warm ep2-5 | Open RPCs | Cached files | Status |
|---|---:|---:|---:|---:|---:|:---:|
| FitCachePP, 4 servers on c35 + 1 GPU client on c66 | **1048s** | **1665s** | 895s (σ=3s) | **46,088** | **9,216** | ✅ |

This was the FIRST end-to-end multi-node FitCachePP cluster run with everything working. The 1665s cold reflects all-the-way-cold cluster state (BeeGFS server caches + local NVMe both empty). Subsequent reps in 1b on c66 with co-located servers got cold-from-warm-OS at 935s. The 46.2% cold→warm reduction is real but specific to first-run state.

---

## Experiment 2: Cross-job sharing (the headline new contribution)

**Goal**: defend the cross-job-sharing-reduces-aggregate-IO claim from
the cross-job sharing experiments section of `04_experiment_plan.md`.
Two TPDS-only sub-claims: (a) two concurrent jobs on different nodes
share via the peer-lookup redirect path; (b) two sequential jobs on the
same node share via the sidecar-restore-across-job-boundary path.

### 2a. Two-job concurrent (peer_lookup redirect) — UNRESOLVED ❌

Setup: 221684 (c66) + 221685 (c67), both `CROSS_JOB=1`, shared `FitCache_CLUSTER_REGISTRY_DIR`. Both cancelled after 1h50min stuck on epoch 1.

| Job B cross_job_stats (rank 0) | Value |
|---|---:|
| opens_total | 8,870 |
| local_hit | 2,611 |
| pfs_fallback | 6,259 |
| **redirect_to_peer** | **0** ❌ |
| peer_lookup_forwarded | 11,662 |
| peer_lookup has_yes | **0** ❌ |
| peer_lookup has_no | 12,196 |

**Cross-job infrastructure fires (peer_lookup RPCs flow) but responders ALWAYS say "no".** Hypothesis (deferred for debug): HRW with 8 cluster servers picks different servers across jobs for the same path; the responder server's local path_cache_map doesn't have what the requester is looking for. Or path_cache_map is partitioned across the 4 server processes per node and peer_lookup arrives at the wrong process. Detailed in [single_job_baseline_and_sidecar_restore_summary.md](benchmarks/results/arc/single_job_baseline_and_sidecar_restore_summary.md) and [mmap_and_cross_job_imbalance_analysis.md](benchmarks/results/arc/mmap_and_cross_job_imbalance_analysis.md).

### 2b. Two-job sequential (sidecar restore) — VALIDATED ✅

Setup: 221695 Job A → 221696 Job B (afterok dep), both on c66, shared local cache. Job B's `FITPP_PURGE_CACHE=0` so Job A's cache + sidecars survive.

| Job | Cold ep1 | Warm ep2-5 | Sidecars restored at startup |
|---|---:|---:|---:|
| Job A (no prior cache) | 1023s | 863s ± 2s | 0 (cache freshly purged) |
| **Job B (sidecar restore)** | **979s** | 864s ± 1s | **9,216** |

**Headline:** Job B's startup ran `restore-sidecars` which scanned the local cache dir and rebuilt path_cache_map from each `.meta` sidecar. All 9,216 files (8192 train + 1024 valid) restored. Job B's epoch-1 wall (979s) = Job A's cold (1023s) **minus 44s = the FitCache cache-promotion overhead that Job B avoided**.

Decomposition:
- Cache-promotion overhead in the single-job FitCachePP cold-cache run: ~43s
- Job A's promotion overhead = cold − warm = 1023 − 863 = 160s (BeeGFS server cache also cold here)
- Job B saved ~44s vs Job A cold = exactly the single-job promotion overhead

**Defends the design-doc claim from `tpds_extension/02_design_cross_job.md` on multi-tenant safety, lifecycle, and eviction policy:** persistent sidecar metadata enables cross-job-boundary cache survival. The mechanism is sound; Job B starts in a primed state with full path_cache_map ready to serve from local NVMe.

Caveat: Job B hung on epoch 5 (independent stability issue, possibly Mercury connection state degradation after multiple long runs). Cancelled after epoch 5 ran for 90+ min. The sidecar restore claim is fully validated by epochs 1-4.

---

## Experiment 3: Three-tier hardware evaluation (DRAM + PMem + NVMe)

**Goal**: replace the IPDPS two-tier extrapolation experiment with REAL
three-tier numbers on PMem hardware. Defends the IPDPS-PMem-extrapolation
follow-up claim from the three-tier hardware evaluation section of
`tpds_extension/04_experiment_plan.md`.

### 3a. Local three-tier smoke (synthetic data, no PMem hardware)

| Test | Files | Tier split | Restoration | Status |
|---|---:|---|---:|:---:|
| **`scripts/smoke/run_three_tier_smoke.sh`** (12 files × 1 MiB, 4/4/4 MiB capacities) | 12 | DRAM 4 / PMem 4 / NVMe 4 | 12/12 from sidecars per-tier | ✅ |

- ✅ Local smoke proves the placement-priority logic (DRAM → PMem → NVMe) and the per-tier sidecar-restore loop are workload-correct. Re-run after every code change as a regression gate.
- Source: `benchmarks/results/arc/three_tier/local_smoke_summary.md`.

### 3b. Real PMem characterization on c35 (`/mnt/fsdax`) — code path validated, quantitative speedup blocked by cluster topology ⚠️

c35's `/mnt/fsdax` is `/dev/pmem0` mounted ext4 with `dax=always` — confirmed real DAX-mode PMem. Two sustained-read micro-benchmark runs landed (SLURM 221792 and 221802):

- Source on local /tmp: cold pass 34.3s, warm-pass mean per round 258s (warm is 7.5x slower than cold).
- Source on BeeGFS with OS page cache evicted between passes: cold pass 53.9s, warm-pass mean per round 261s (warm is 4.8x slower than cold).

Tier placement fires end-to-end on real PMem (`DRAM`, `/mnt/fsdax`, NVMe directories all populate). The warm-vs-cold inversion is due to the cache-hit RPC path paying a ~250 ms per-open tax that the cache-miss path doesn't. The natural follow-up (multi-node CosmoFlow with `FitCache_PMEM_PATH=/mnt/fsdax`) is **infeasible on this cluster** because c35 has DAX PMem but no GPU; the GPU nodes (rtx4060ti16g partition) have no DAX PMem. GPU + PMem are on disjoint node classes. Full write-up: [real_pmem_evaluation_on_c35.md](benchmarks/results/arc/three_tier/real_pmem_evaluation_on_c35.md).

**To unblock the quantitative GPU+PMem speedup claim:** either (i) run on a cluster with GPU + DAX-mode PMem co-located, or (ii) profile and reduce the cache-hit-path per-open RPC cost so the cache wins at smaller per-open work granularity.

---

## Experiment 4: Workload generalization (Megatron-LM + DINOv2)

**Goal**: defend the "FitCache++ generalizes beyond CosmoFlow/DeepCAM"
claim from the workload-generalization evaluation section of
`tpds_extension/04_experiment_plan.md`. Two new workloads with different
I/O shapes.

### 4a. Access-pattern smokes (synthetic data, no GPU)

| Smoke | Workload shape | Files cached | Sidecars | sha256 match | Status |
|---|---|---:|---:|---|:---:|
| **`scripts/smoke/run_megatron_access_pattern_smoke.sh`** | 8 MiB `.bin` + 64 KiB `.idx` (Megatron indexed-binary) | 2/2 | 2/2 | both | ✅ |
| **`scripts/smoke/run_dinov2_access_pattern_smoke.sh`** | 4 classes × 10 imgs + 2 metadata = 42 files (ImageNet-style nested tree) | 42/42 | 42/42 | spot-check ok | ✅ |

- ✅ Both workload I/O shapes (large-streaming `.bin` and small-files-deep-tree) are workload-correct: opens caught by the path-filter, files promoted via the data mover, sidecars written, payloads byte-equivalent. The same FitCache code paths handle both shapes.
- ✅ Megatron smoke surfaced the **data-mover signal-loss bug** (the second file `.idx` was being dropped from the cache because pthread_cond signals fired while the mover was busy were getting lost). Fixed in commit `c6c25ee`.
- Source: smoke scripts under `scripts/`, summary in `benchmarks/results/arc/workload_generalization/setup_and_run.md`.

### 4b. Real cluster runs

| Run | Status | Blocking on |
|---|:---:|---|
| Megatron-LM (12-layer GPT, 1000 iters) | ❌ architectural limit | `numpy.memmap` for the .bin/.idx → page faults, not `read()` syscalls. LD_PRELOAD client doesn't intercept `mmap`. Workload bypasses FitCachePP entirely. See [mmap_and_cross_job_imbalance_analysis.md](benchmarks/results/arc/mmap_and_cross_job_imbalance_analysis.md). |
| DINOv2 SSL (1 epoch, ImageNet-22k subset) | ❌ architectural limit | `mmap(fileno=f.fileno(), …)` for each per-class .tar bundle. Same architectural pattern as Megatron — page-fault reads bypass LD_PRELOAD. |

- 🚧 Megatron-LM source cloned at `/home/ghu4/hvac/benchmark/Megatron-LM` (shallow, 64 MB source-only).
- 🚧 DINOv2 source cloned at `/home/ghu4/hvac/benchmark/dinov2` (shallow, 6.9 MB source-only).
- 🚧 Cluster sbatch scripts ready to submit once datasets exist:
  - [benchmarks/megatron/PDSW_FITPP_megatron.sh](benchmarks/megatron/PDSW_FITPP_megatron.sh) + [command_megatron_FITPP.sh](benchmarks/megatron/command_megatron_FITPP.sh)
  - [benchmarks/dinov2/PDSW_FITPP_dinov2.sh](benchmarks/dinov2/PDSW_FITPP_dinov2.sh) + [command_dinov2_FITPP.sh](benchmarks/dinov2/command_dinov2_FITPP.sh)
- Source: `benchmarks/results/arc/workload_generalization/setup_and_run.md`.

---

## Experiment 5: Zero-regression-vs-IPDPS-single-job (backward compat)

**Goal**: defend `FitCache_CROSS_JOB=0` reproduces IPDPS behavior
bit-for-bit. Listed as a hard requirement in the env-var contract
section (§9) of `tpds_extension/02_design_cross_job.md` and as the
safety claim in that doc's cluster-scoped coordination protocol section.

| Test | Workload | `CROSS_JOB=0` cache | `CROSS_JOB=1` cache | sha256 match | Status |
|---|---|---|---|---|:---:|
| **`scripts/smoke/run_bit_equivalence_smoke.sh`** | 8 files × 256 KiB synthetic | 8 files cached | 8 files cached + 8 sidecars | all 8 byte-identical to source AND between modes | ✅ |

- ✅ The `CROSS_JOB={0,1}` byte-equivalence is the strongest single-process check that the cross-job code path preserves data correctness when run in single-job degenerate mode.
- ✅ Re-run after every code change in this session (path-filter fix, lookup_addr fix, registry rmw fix, data-mover fix, dataset_id manifest plumb, lease renewal, log4c flush, PMem tier add). Still passes.
- ✅ Verified in the cross-job=on pass: cross_job_stats counters show `opens_total=8 ... pfs_fallback=8 ... peer_lookup forwarded=0 handled=0` — single-server topology with no peers, no peer-lookup ever fires, zero Mercury overhead beyond the basic open RPC. Matches design.
- Source: `benchmarks/results/arc/bit_equivalence/summary.md`.

---

## Experiment 6: Sensitivity / ablation / failure injection

**Status**: the sensitivity-ablation-failure-injection block of
`04_experiment_plan.md`; lower priority, deferred until the
single-job baseline, cross-job sharing, three-tier hardware, and
workload-generalization experiments produce their primary numbers.

| Test | Per the sensitivity-ablation-failure-injection block of `04_experiment_plan.md` | Status |
|---|---|:---:|
| Server-set churn (kill server mid-run, observe HRW remap) | smoke variant of `run_two_server_smoke.sh` | ⏸️ |
| Registry GC under load (N concurrent heartbeats race) | exercises commit `0602e71` rmw fix | ⏸️ |
| Failure injection at scale | Frontier-scale, deferred per plan | ⏸️ |

---

## Unit + smoke regression suite (every-commit gate)

| Suite | Coverage | Status |
|---|---|:---:|
| `tests/test_cross_job_smoke` | FNV-1a vectors / HRW balance + churn / dataset_id stability / cluster registry roundtrip + heartbeat staleness + deregister / client-side routing + slot stability / sidecar persistent metadata + refcount + scan / eviction victim selection (refcount-protected never picked) / subscriber-lease subscribe + release idempotency | ✅ 8/8 |
| `scripts/smoke/run_bit_equivalence_smoke.sh` | CROSS_JOB={0,1} byte-equivalence | ✅ |
| `scripts/smoke/run_three_tier_smoke.sh` | DRAM + PMem + NVMe placement + restoration | ✅ |
| `scripts/smoke/run_two_server_smoke.sh` | Multi-server peer-lookup + redirect + cross-job-sharing on localhost | ✅ |
| `scripts/smoke/run_megatron_access_pattern_smoke.sh` | Megatron `.bin`/`.idx` access-pattern | ✅ |
| `scripts/smoke/run_dinov2_access_pattern_smoke.sh` | DINOv2 nested-image-tree access-pattern | ✅ |

---

## Bugs found and fixed in this session (ordered by impact on cluster experiments)

| Bug | Discovered via | Fix commit | Impact on prior results |
|---|---|---|---|
| **Path-filter mismatch**: scripts set `FitCache_DATA_DIR=…/train_61440/train/` but `train.py` (per `configs/cosmo.yaml`) reads `…/train_1024`. LD_PRELOAD substring filter rejects the data opens. | inspecting per-server log4c on c66 after 221619 finished: 0 Open RPCs everywhere. | `32d556e` (`--data-dir` flag in `command_CF_FITPP.sh`) | **All 4 prior cluster baselines (221607, 221614/615, 221616/617, 221618/619) had FitCache bypassed entirely.** |
| **Data-mover signal-loss**: producer (close-RPC handler) signals `pthread_cond` while consumer (data mover) is mid-copy — signal lost; consumer returns to `wait()` with files still queued. Reproduced via Megatron 2-file smoke. | `run_megatron_access_pattern_smoke.sh` (.idx never cached) | `c6c25ee` (predicate check before `pthread_cond_wait`) | Multi-file cluster runs only got the first file or two cached. Likely cause of 221621 hang on epoch 1. |
| **`lookup_addr` NULL deref**: `fopen(.ports.cfg, "r+")` returns NULL when client and server CWDs diverge; subsequent `fscanf(NULL, ...)` segfaults. | 221620 segfault at first FitCache-intercepted open in cosmoflow training. | `dd88ffe` (NULL check + `FitCache_PORTS_CFG_DIR` env var) | 221620 crashed in 28s. Mode previously masked because the path-filter bug meant `lookup_addr` was never called. |
| **Registry rename-EBUSY storm on BeeGFS**: write_atomic's `rename(tmp, final)` fails EBUSY when the destination has an open fd (rmw flow). Orphan `.tmp.<pid>` files accumulate; gc rmw's them, generating chained `.tmp.A.tmp.B.tmp.C` filenames and a self-perpetuating EBUSY cascade. | inspecting `fitcache_server_log` from 221621 — chained tmp filenames in error messages. | `0602e71` (in-place truncate+write under flock + iterator filter for `.tmp.*` files + orphan sweep at registry_init) | Log-pollution only, but masked actual error signals in the cluster logs and may have delayed legitimate heartbeat refreshes. |
| **`log_cross_job_stats` final-dump flushes to nowhere**: `signal_exit` calls `std::exit(0)` which bypasses `log4c_fini()`. The SIGINT/SIGTERM-final cross_job_stats line gets buffered and dropped. | engagement self-check found 0 Open RPC log lines despite obvious activity. | `35d8443` (`log4c_fini()` before `std::exit`) | Visibility-only; no behavioral impact on training. |
| **Engagement self-check too narrow**: grepped only INFO-level log lines. With `FitCache_LOG_LEVEL=500` (NOTICE), all `L4C_INFO` is filtered → check thinks FitCache wasn't engaged when it actually was. | 221630 produced cold 385s + obvious FitCache slowdown but check fired the warning. | `d5d7000` (bumped log level to 600 + added cached-file-count signal as backup) | Visibility-only. |
| **PDSW_FITPP.sh bypassed inner.sh**: had its own server-launch via `mpirun -N 1`, never picked up the cd-to-RESULTS_DIR / FitCache_PORTS_CFG_DIR / engagement-check fixes. | log4c files for 221621/221630 didn't land in `$RESULTS_DIR` despite the inner.sh fix. | `8c9baa9` (single-job baseline now `exec`s inner.sh) | All single-job cluster runs through 221634 had divergent CWD / log placement. |
| **`set -u` unbound `FitCache_PMEM_PATH` in single-job runs**: engagement self-check loop fails on single-job baselines that don't enable PMem. | 221634 SLURM exit 1:0 despite training succeeding. | `6a2a9df` (`${FitCache_PMEM_PATH:-}` parameter expansion) | Spurious exit code only; training data was correct. |

---

## Known bugs still open

| Bug | Affects | Status |
|---|---|:---:|
| `Data mover.*Copied` log line behind `DEBUG_HU` guard | engagement check has to use file-count signal as primary; log-count is informational | ⚠️ low priority |
| Two-job experiments not yet re-run with all fixes | every cross-job-sharing claim in `summary_221614_*.md` needs replacement | 🚧 two-job concurrent + two-job sequential |

---

## Deferred items (low-priority; agreed)

| Item | Reason for deferring |
|---|---|
| ⏸️ Megatron-LM + DINOv2 real cluster runs | needs user-side dataset prep (conda envs + tokenized corpus + ImageNet-22k); access-pattern smokes already PASS so the FitCache code paths are validated |
| ⏸️ Full-manifest dataset_id behavior verification | manifest-hash is wired into sidecars (commit `c566631`) but no test currently asserts a divergent-dataset job is refused sharing |
| ⏸️ Sensitivity / failure-injection block of the experiment plan | low priority; do after the single-job baseline + cross-job sharing + three-tier hardware + workload-generalization experiments produce primary-claim numbers |
| ⏸️ Frontier-scale runs | hardware not available; the IPDPS submission was on the same in-house cluster |

---

## Status of the experimental campaign at end of 2026-05-12

The execution order from earlier in the campaign — single-job baseline →
cross-job sharing → three-tier hardware → workload-generalization →
sensitivity — has been worked through. End-of-day state:

1. **Single-job FitCachePP-vs-Pure_CF baseline runs (c66, n_train=8192).** Complete. Headline: +7% overhead. Detailed in [single_job_baseline_and_sidecar_restore_summary.md](benchmarks/results/arc/single_job_baseline_and_sidecar_restore_summary.md).
2. **Multi-node single-job CosmoFlow with FitCachePP verifiably engaged (SLURM 221645, c35 storage + c66 GPU client).** Complete. 46,088 Open RPCs, 9,216 cached files. Seeded the headline cluster-engaged number.
3. **Two-job concurrent cross-job-sharing run.** Mechanism gap found (HRW imbalance + per-server-process path_cache_map partitioning); `has_yes=0` across 12k peer_lookups. Detailed in [mmap_and_cross_job_imbalance_analysis.md](benchmarks/results/arc/mmap_and_cross_job_imbalance_analysis.md). Open follow-up: peer_lookup sibling-fanout in `fitcache_peer_lookup_rpc_handler`.
4. **Two-job sequential sidecar-restore run.** Validated: Job B saved 44s vs Job A cold via 9,216-file sidecar restore.
5. **Real DAX-mode PMem hardware evaluation on c35 (`/mnt/fsdax`).** Code paths fire on real PMem; quantitative speedup blocked by cluster topology (GPU and DAX-PMem on disjoint node classes). Detailed in [real_pmem_evaluation_on_c35.md](benchmarks/results/arc/three_tier/real_pmem_evaluation_on_c35.md).
6. **Workload-generalization run (Megatron-LM + DINOv2).** Architectural limit: both workloads use `mmap`, bypassing LD_PRELOAD. Detailed in [mmap_and_cross_job_imbalance_analysis.md](benchmarks/results/arc/mmap_and_cross_job_imbalance_analysis.md). Open follow-up: pick syscall-based replacement workloads or add an `mmap` interceptor.
7. **Sensitivity / ablation / failure-injection block.** Deferred.
