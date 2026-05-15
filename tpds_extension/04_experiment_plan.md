# Experiment Plan for FitCache++ TPDS Extension

**Purpose:** exact configurations, baselines, metrics, and plots for the new evaluation work — the three-tier hardware evaluation, the workload-generalization evaluation, the cross-job sharing experiments, and the sensitivity / ablation / failure-injection evaluation. Designed to (a) defend the new claims that the cluster-scoped coordination protocol and the multi-tenant safety/lifecycle/eviction policy enable, (b) close the two-tier extrapolation experiment from the IPDPS paper, (c) demonstrate workload generalization beyond CosmoFlow/DeepCAM.

**Anchored to:** [02_design_cross_job.md](02_design_cross_job.md) (knobs we have) and [03_related_work.md](03_related_work.md) (baselines we owe the reviewer).

**Resource assumption:** "plenty of Frontier hours" per user; ARC (= GPUCLUSTER in the IPDPS paper anonymized name; PMem nodes available) freely available for smaller-scale experiments.

**Test-bed split.** Where each section runs:
- **ARC**: the three-tier hardware evaluation (only ARC has PMem) and the early cross-job smoke tests (cheap, debug-friendly)
- **Frontier**: the large-scale workload-generalization evaluation, the 2048-GPU cross-job scale test, and the failure-injection-at-scale evaluation
- **Either**: the smaller cross-job experiments and most sensitivity / ablation runs — start on ARC, scale up to Frontier once they pass

---

## 0. Top-line claims to defend

The evaluation must support these specific claims in the introduction. Use the descriptive name when citing them in prose.

| Claim | Defended by |
|---|---|
| **Cross-job-sharing-reduces-aggregate-I/O claim:** Cross-job sharing reduces aggregate I/O time vs. independent caching | The concurrent-jobs experiment + the sequential-reuse experiment |
| **Cross-job-scales-to-leadership-class claim:** Cross-job sharing scales to leadership-class systems | The 2048-GPU multi-job cross-job scale test |
| **Three-tier-beats-two-tier claim:** Three-tier (DRAM+PMem+NVMe) outperforms two-tier when DRAM is undersized | The three-tier hardware evaluation |
| **Design-generalizes-beyond-CosmoFlow/DeepCAM claim:** The design generalizes beyond CosmoFlow/DeepCAM | The workload-generalization evaluation (LLM + GNN) |
| **Bounded-recovery-cost claim:** The system tolerates server failures with bounded recovery cost | The failure-injection evaluation |
| **Zero-regression-vs-IPDPS-single-job claim:** Cross-job mode never regresses single-job mode | The bit-equivalence sub-experiment (`FitCache_CROSS_JOB=0` against the IPDPS configs) |

Every figure/table in the four new evaluation subsections maps to one of these claims. If a planned plot doesn't, it gets cut.

---

## 1. Baselines (must run, in priority order)

Use the descriptive name when citing. The order below is priority order, not a label.

| Baseline | What it represents | Where to compare |
|---|---|---|
| **Lustre Orion / BeeGFS PFS direct** | No caching | All experiments |
| **HVAC (NVMe-only, single-job)** [Khan et al. CLUSTER'22] | IPDPS baseline | All experiments |
| **HVAC + HashRing fault-tolerance** [SC'24-PDSW] | Contemporaneous fault-tolerance baseline | Failure-injection evaluation, 2048-GPU scale test |
| **FitCache (IPDPS version, single-job, two-tier)** | Our own prior work | All experiments |
| **FitCache++ (cross-job OFF)** | Confirms zero regression of new code in single-job mode | Bit-equivalence sub-experiment, smoke tests |
| **FitCache++ (cross-job ON)** | Our new system | All cross-job experiments |
| **Lustre PCC RO-PCC** [Li et al. SC'19] | Closest persistent-cache competitor | The 2048-GPU scale test if time permits |

Note: The Lustre PCC baseline requires a Lustre version with PCC enabled and may not be runnable on Frontier without admin support. Mark as "stretch goal." Without it we still have a strong story; the diff is well-articulated in the design doc textually.

---

## 2. Metrics

Standard:
- **End-to-end training time** per epoch and total
- **Per-batch I/O latency** (mean, p95, p99, tail)
- **GPU utilization** (sampled via rocm-smi/nvidia-smi)
- **Aggregate read throughput** (GB/s, summed across nodes)

New / specific to cross-job:
- **Cross-job cache hit ratio**: fraction of file opens served from a peer-job cache vs. local cache vs. PFS
- **Cold-start time**: wall-clock time of epoch-0 of a job, with and without warm peer caches
- **Eviction rate under multi-tenant pressure**: evictions/sec, refcount-zero fraction
- **Subscriber-lease overhead**: registry RPCs/sec, p99 lookup latency
- **Recovery time after server kill** (failure-injection evaluation)

Reporting: 3 runs per configuration, 95% CI on the dominant metric. Match the IPDPS reporting style.

---

## 3. Three-tier hardware evaluation

### Goal (the three-tier-beats-two-tier claim)
Empirically validate the IPDPS paper's two-tier extrapolation. Show that adding PMem between DRAM and NVMe gives a measurable speedup when DRAM alone can't hold the dataset.

### Platform
**GPUCLUSTER** primary. The two PMem nodes are the only place we can run real DRAM+PMem+NVMe simultaneously. (Frontier nodes don't have PMem; we acknowledge this as a limitation and discuss CXL as the path forward in the lessons-learned discussion subsection.)

### Configurations

Workload: CosmoFlow on cosmoUniverse (1.3 TB).
Per-node tier capacities are deliberately constrained so the dataset doesn't fit in the fastest tier:

| Configuration | DRAM | PMem | NVMe | Expected behaviour |
|---|---|---|---|---|
| **DRAM-only** | 64 GB | – | – | Mostly miss → falls to PFS; baseline-bad |
| **NVMe-only** | – | – | 1 TB | IPDPS HVAC analog |
| **DRAM + NVMe (two-tier)** | 64 GB | – | 1 TB | IPDPS FitCache analog |
| **PMem-only** | – | 256 GB | – | Quantifies PMem alone |
| **DRAM + PMem** | 64 GB | 256 GB | – | New — fast tier total fits dataset partially |
| **DRAM + PMem + NVMe (three-tier)** | 64 GB | 256 GB | 1 TB | **The claim** — hierarchical fit |

GPU count: hold at 4 GPUs (small enough that I/O is the dominant cost; large enough to be representative). Run for 5 epochs to see warm-cache behavior.

### Plots
- **Per-epoch-time bar chart** across the six tier configurations, with epoch 1 (cold) and epoch 5 (warm) side-by-side.
- **Per-batch I/O latency CDF** for two-tier (DRAM + NVMe) vs three-tier (DRAM + PMem + NVMe) — should show the three-tier tail tightening because PMem catches what spills out of DRAM.
- **Speedup-vs-DRAM-size sensitivity plot:** vary DRAM size from 16GB to 256GB; plot speedup of three-tier over two-tier vs. DRAM size. Demonstrates "PMem helps most when DRAM is small," which directly supports the hierarchical-fit narrative.

### Compute budget
~40 GPU-hours on GPUCLUSTER. ~80 hours wall if run sequentially with the two available PMem nodes; can be parallelised across the two nodes for ~40 hours wall.

---

## 4. Workload-generalization evaluation

### Goal (the design-generalizes-beyond-CosmoFlow/DeepCAM claim)
Show FitCache++ accelerates workloads with very different access patterns than CosmoFlow/DeepCAM. Two new workloads: **Megatron-LM pretraining** (sequential streaming over large tokenized chunks) and **DINOv2 self-supervised pretraining** (large random reads of image tensors).

### Megatron-LM pretraining

Setup: Megatron-LM training of a small Llama-architecture model (~1.3B params) on a tokenized RedPajama or C4 slice.
- Tokenized dataset size: 1–2 TB (chunked .bin / .idx files, each ~100MB–1GB)
- Access pattern: many concurrent ranks reading sequentially through a shuffled list of chunks; mmap-based loaders
- Frontier scale: 256 GPUs and 1024 GPUs

Configurations to compare: PFS direct, HVAC, FitCache (IPDPS), FitCache++ (cross-job ON).

Plots:
- **Per-epoch-time bar chart** across baselines at 256 and 1024 GPUs.
- **Token-throughput vs GPU count** — should scale better under FitCache++ if I/O is the bottleneck.
- **Per-batch breakdown table** (compute / data / comm / other) at 1024 GPUs, similar to Fig 8 of the IPDPS paper.

### DINOv2 self-supervised vision pretraining

Setup: DINOv2 pretraining on ImageNet-22K (or LAION-style large image corpus).
- Dataset size: 1.4 TB raw images (≈14M images, ~100KB each)
- Access pattern: very large file count, random shuffled access per epoch — stresses the small-file metadata path that PFS handles poorly
- Frontier scale: 256 GPUs and 1024 GPUs

This complements Megatron-LM: Megatron-LM = few large sequential files; DINOv2 = many small random files. Together they bracket the access-pattern space well.

Configurations: PFS direct, HVAC, FitCache (IPDPS), FitCache++ (cross-job ON).

Plots:
- **Per-epoch-time bar chart**.
- **Per-image-open latency CDF.** FitCache++ should have a much tighter tail because small-file metadata gets cached locally.
- **GPU utilization timeline** — FitCache++ should reduce data-stall idle gaps.

### Compute budget
- Megatron-LM (256 GPU × 2 hours × 4 baselines × 3 reps + 1024 × 2 × 4 × 3) ≈ 6,144 + 24,576 = ~30k GPU-h
- DINOv2 (256 × 2 × 4 × 3 + 1024 × 2 × 4 × 3) ≈ 6,144 + 24,576 = ~30k GPU-h
- Plus warm-up and pilot runs: ~10k GPU-h slack

**Total workload-generalization budget ≈ 70,000 GPU-hours on Frontier.** This is the largest single block in the campaign — order it early. The DINOv2 swap (vs the original GNN plan) raises the budget because DINOv2 wants the same scale as Megatron-LM to make the small-file story credible.

---

## 5. Cross-job sharing experiments

### Concurrent-jobs experiment (the cross-job-sharing-reduces-aggregate-I/O claim)

Two jobs (Job A and Job B) start within Δt of each other, both read the full cosmoUniverse dataset for 3 epochs.

| Configuration | A's mode | B's mode | Expectation |
|---|---|---|---|
| **No-cache baseline** | FitCache++ off | FitCache++ off | Both pay full PFS cost; baseline |
| **Independent caches** | FitCache++ on (single-job semantics) | FitCache++ on (single-job semantics) | Each job has its own cache; no sharing |
| **Cross-job sharing** | FitCache++ on, cross-job | FitCache++ on, cross-job | A warms cache, B reads from A's cache |

Δt sweep: {0, 30s, 5min, full epoch}. Captures different overlap scenarios.

GPU count: 64 per job (small enough to run many configurations cheaply).

Plots:
- **Per-job total training time** across the three configurations × Δt sweep. Two grouped bars per Δt (A and B).
- **Cross-job cache hit ratio for B over time**, line plot.
- **Aggregate cluster I/O bytes-from-PFS vs. time**, three lines.

### Sequential-reuse experiment (the cross-job-sharing-reduces-aggregate-I/O claim, cold-start variant)

Job A runs to completion, Job B starts after Job A exits. Tests that the cache *persists across the job boundary*.

Two variants:
- **Immediate-reuse** (Δexit = 0s, B starts immediately)
- **Delayed-reuse** (Δexit = 30 min, cache reaper may have started; tests refcount/lease semantics)

Plot:
- **B's epoch-0 time** across (FitCache off, FitCache++ single-job, FitCache++ cross-job). The cross-job bar should be ~equal to a warm cache.

### Cross-job scale test (the cross-job-scales-to-leadership-class claim)

The cross-job-sharing configuration of the concurrent-jobs experiment, but at **1024 GPUs per job × 2 concurrent jobs = 2048 GPUs**. Single largest cross-job experiment. Compares against HVAC and HVAC+HashRing at the same scale.

Plot:
- **Per-job training time at 1024-GPU scale**, bar chart, four baselines.
- **Cross-job cache hit ratio at scale** (table).

### Multi-tenant-pressure experiment (cross-job-sharing-reduces-aggregate-I/O claim, eviction variant)

Eight concurrent jobs on a fixed-capacity cache that can hold only ~50% of the union of their datasets. Tests refcount + lease eviction policy under genuine pressure.

Configurations:
- **Refcount + LRU policy (ours)**
- **Naive LRU ablation** (no refcount)
- **No cross-job** (each job has its own private cache, with proportional share of total capacity)

Plot:
- **Aggregate completion time across all 8 jobs**, three bars.
- **Eviction rate over time**, three lines.

### Compute budget for cross-job sharing experiments
- Concurrent-jobs (64 GPU × 2 jobs × ~30 min × ~12 configurations × 3 reps) ≈ 2,300 GPU-h
- Sequential-reuse (64 × 2 × ~30 × 6 × 3) ≈ 1,150 GPU-h
- Cross-job scale test (1024 × 2 × ~30 × 4 × 3) ≈ 12,300 GPU-h
- Multi-tenant-pressure (64 × 8 × ~45 × 3 × 3) ≈ 6,900 GPU-h
- Total ≈ 22,650 GPU-h on Frontier.

---

## 6. Sensitivity, ablation, and failure-injection evaluation (the bounded-recovery-cost and zero-regression claims)

### Server-count sweep (extension of the IPDPS scale studies)
Same ablation as Fig 9 of the IPDPS paper, but now with cross-job mode on. Sweep 1, 2, 4, 8, 16 servers per node.

### Hash-function ablation (motivates rendezvous hashing)
Compare: (a) modulo hash (IPDPS), (b) consistent hash, (c) rendezvous hash (ours). For each, measure:
- Cross-job hit rate when N differs between jobs (Job A=4 servers/node, Job B=2 servers/node)
- Modulo should fail; consistent should partially work; HRW should be best.

Plot:
- **Cross-job hit rate vs. (N_A, N_B) configurations**, three lines.

### Failure-injection sub-experiment (the bounded-recovery-cost claim)
Cross-job training in progress on 64 GPUs. SIGKILL one FitCache server at t=30s into epoch 2. Measure:
- Time until clients detect the failure
- Time until training resumes
- Per-batch I/O latency before/during/after the failure window

Compare against HVAC+HashRing which has its own fault-tolerance story.

Plot:
- **Per-batch I/O latency time series across the kill event**; FitCache++ vs HVAC+HashRing.
- **Recovery time table** (median, p95).

### Bit-equivalence sub-experiment (the zero-regression-vs-IPDPS-single-job claim)
With `FitCache_CROSS_JOB=0`, run the configurations from Figs 6 and 7 of the IPDPS paper and verify within-CI equivalence with the published IPDPS numbers.

Plot:
- **Per-config FitCache (IPDPS) vs FitCache++ (cross-job=off) wall-clock time** (table).

### Dataset-fingerprint cost ablation
Vary `FitCache_DATASET_FINGERPRINT_SAMPLES` ∈ {0, 4, 16, 64}. Measure startup time penalty and false-non-share rate (synthetic).

### Compute budget for sensitivity / ablation / failure-injection evaluation
~3,000 GPU-h.

---

## 7. Total Frontier campaign budget

| Section | GPU-hours |
|---|---|
| Three-tier hardware evaluation (on ARC, not Frontier) | (40 GPU-h on ARC) |
| Workload-generalization — Megatron-LM | ~30,000 |
| Workload-generalization — DINOv2 | ~30,000 |
| Cross-job sharing experiments | ~23,000 |
| Sensitivity / ablation / failure-injection evaluation | ~3,000 |
| Pilot, debug, lost runs (estimate +30%) | ~26,000 |
| **Total** | **~112,000 GPU-h on Frontier** |

For context, the IPDPS paper's largest experiments (2048 GPUs × multiple epochs across CosmoFlow + DeepCAM) ran on a similar order-of-magnitude allocation. This is in the realistic range for the cited "plenty of hours."

---

## 8. Order of execution (defensive sequencing)

Run experiments in the order that minimizes risk of the campaign blowing up. Each block names what is run, not a phase number.

**Smoke block (~1 week wall, ~2k GPU-h).**
- Bit-equivalence sub-experiment (`FitCache_CROSS_JOB=0` against the IPDPS configs). **If this fails, halt and fix before going further** — it means the new code regressed something.
- Three-tier hardware-evaluation pilot on GPUCLUSTER (PMem nodes only, 1 GPU, 1 epoch).
- A single small cross-job run at 16 GPUs to validate the new RPC paths, registry, and HRW routing end-to-end.

**Core-claims block (~3 weeks wall, ~30k GPU-h).**
- Concurrent-jobs experiment + sequential-reuse experiment (small-scale, 64 GPUs)
- Server-count sweep + hash-function ablation
- Three-tier hardware evaluation full sweep on GPUCLUSTER

**Scale block (~3 weeks wall, ~35k GPU-h).**
- Cross-job scale test (2048 GPUs)
- Workload-generalization Megatron-LM at 256 and 1024 GPUs
- Workload-generalization DINOv2 at 256 and 1024 GPUs

**Stretch block (~1–2 weeks wall, ~10k GPU-h).**
- Multi-tenant-pressure experiment
- Failure-injection sub-experiment
- Dataset-fingerprint cost ablation
- Lustre PCC baseline if accessible

This ordering ensures the most important claim (cross-job sharing works) is validated at small scale before we spend the largest GPU blocks on it.

---

## 9. Plots → paper-figure budget

Total: 9 figures + 4 tables for the four new evaluation subsections.

Combined with the existing IPDPS evaluation figures (5–9), the journal evaluation will have ~14 figures + 6 tables. That's appropriate journal density.

| Figure | Subsection | Purpose |
|---|---|---|
| Per-epoch bar across 6 tier configs | Three-tier hardware evaluation | Direct claim defence |
| Per-batch I/O CDF, two-tier vs three-tier | Three-tier hardware evaluation | Tail-latency story |
| Speedup vs DRAM size, sensitivity | Three-tier hardware evaluation | When does the third tier matter |
| Megatron-LM per-epoch time | Workload-generalization evaluation | LLM scaling story |
| Megatron-LM token-throughput scaling | Workload-generalization evaluation | I/O bottleneck check |
| DINOv2 per-epoch time | Workload-generalization evaluation | Small-file story |
| DINOv2 per-image-open CDF | Workload-generalization evaluation | Metadata-path story |
| Concurrent jobs total time + Δt sweep | Cross-job sharing experiments | Headline claim defence |
| Sequential cold-start elimination | Cross-job sharing experiments | Cache persistence story |
| Scale to 2048-GPU cross-job | Cross-job sharing experiments | Leadership-class scaling |
| Multi-tenant eviction behaviour | Cross-job sharing experiments | Eviction policy defence |
| Hash-function ablation | Sensitivity / ablation / failure-injection | Routing-choice motivation |
| Failure-injection time series | Sensitivity / ablation / failure-injection | Recovery story |

(Tables: bit-equivalence sub-experiment; cross-job hit-rate at scale; Megatron-LM batch breakdown; failure recovery time.)

---

## 10. Risks specific to the experiment campaign

R1. **LLM pretraining at 1024 GPUs is expensive and finicky.** Mitigation: start with 256 GPUs; if numbers are clean, scale up. Don't burn 1024-GPU hours debugging.

R2. **DINOv2 reproducibility on Frontier with ROCm.** The reference DINOv2 implementation is CUDA-centric. Mitigation: validate the ROCm port early on a small ImageNet-1K subset before committing to ImageNet-22K runs; document the exact PyTorch/ROCm versions in supplementary.

R3. **HVAC + HashRing (SC'24) reproducibility.** The PDSW paper may not have a public release. If we can't reproduce exactly, fall back to citing their numbers and running our own equivalent fault-tolerance comparison via the failure-injection sub-experiment.

R4. **The multi-tenant-pressure experiment requires 8 concurrent jobs.** Frontier scheduler may not let us hold 8 concurrent allocations easily. Mitigation: simulate via 8 MPI sub-allocations under one parent job.

R5. **PMem on GPUCLUSTER is limited to 2 nodes.** Mitigation: run the three-tier hardware evaluation purely on those 2 nodes; small but sufficient for a single-node-per-job sensitivity story. Optionally explore Frontier/CXL alternatives during the stretch block.

R6. **The dataset-fingerprint manifest scan may be slow on first run for huge datasets.** Mitigation: the dataset-fingerprint cost ablation explicitly measures and bounds this; mitigations are already in the dataset-identity-descriptor subsection of the design doc.

R7. **Cross-job mode could turn out to have a worse cold-start than single-job mode** (more RPC traffic to consult registry). Mitigation: the concurrent-jobs experiment's "Δt = 0" configuration measures exactly this; if there's a regression, we tune the lookup-skip heuristic before the scale runs.

---

## 11. Outputs needed before implementation starts

For the implementation step, we need to know:
- ✅ Exact RPCs to add (specified in the "New / modified RPCs" subsection of the design doc)
- ✅ Files to add/modify (specified in the "Implementation skeleton" subsection of the design doc)
- ✅ Env-var contract (specified in the "Configuration surface" subsection of the design doc)
- ✅ Acceptance tests (the smoke block above is the acceptance test)

We're ready to start coding. The smallest end-to-end milestone is:
1. Implement the cluster registry (registry file format, write/read, heartbeat thread).
2. Implement HRW routing (selectable via env var).
3. Implement a stubbed `peer_lookup` RPC that always returns "no" — proves the new RPC plumbing works without any cache changes.
4. Run the bit-equivalence sub-experiment as the smoke test.

That's a ~1–2 week implementation slice with a real test gate. After that, the cache-side changes (sidecar metadata, refcount, real eviction) are the second slice.

---

End of experiment plan. Step 4 complete; ready for the implementation step.
