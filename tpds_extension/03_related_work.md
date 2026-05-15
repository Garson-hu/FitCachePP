# Related Work Survey for FitCache++ TPDS Extension

**Purpose:** identify which existing systems we must (a) cite, (b) compare against, (c) explicitly differentiate from, given the new cross-job + three-tier scope. Anchored to the design in [02_design_cross_job.md](02_design_cross_job.md).

This is a working survey, not the final paper background section. It captures *what we now know* and *what's still open* (papers to read in full before writing).

---

## 1. Streams

The cross-job + three-tier extension touches five literature streams:

| Stream | What we need from it |
|---|---|
| DL-specific I/O caching (HVAC, SHADE, DIESEL, Quiver, NoPFS, FanStore) | Direct competitors; must position against |
| Generic distributed/multi-tier caching (Hermes, Kangaroo, Redis, Memcached) | Adjacent prior art for the design subsections |
| Multi-tenant DL cluster characterization (Philly, Alibaba PAI traces) | Empirical motivation for cross-job sharing |
| PFS-side caching (Lustre PCC, burst buffers) | Closest existing "persistent client cache" prior art — must differentiate |
| CXL / disaggregated memory & FAM (TrainingCXL, FamFS, Beluga) | Forward-looking discussion in the lessons-learned subsection |

---

## 2. DL-specific I/O caching (direct competitors)

### HVAC [Khan et al. CLUSTER'22]
- **What:** Read-only NVMe-side LD_PRELOAD cache for DL on Frontier/Summit. The IPDPS FitCache paper's primary baseline.
- **2024 update:** "Fault-Tolerant Deep Learning Cache with Hash Ring for Load Balancing in HPC Systems" (PDSW @ SC'24, Lee et al.) — adds elastic recaching via a hash ring on top of HVAC, evaluated on 1,024 Summit nodes. **This is new and important**: it competes with FitCache++ on fault tolerance.
- **Position:** Still *single-tier (NVMe), single-job*. Cross-job sharing and DRAM/PMem tiers are out of scope. The 2024 SC fault-tolerance paper is the closest contemporaneous work to our cluster-scoped failure-mode design — we should cite it and compare *fault recovery time* in the failure-injection evaluation.
- URL: https://dl.acm.org/doi/10.1109/SCW63240.2024.00176

### SiloD [Zhao et al. EuroSys'23]
- **What:** Co-design of cache and scheduler for DL clusters. Treats cache and remote I/O as first-class scheduling resources. Reports up to 7.4× JCT improvement.
- **Position:** *Co-design* angle is different from FitCache++. SiloD assumes the scheduler can be modified; FitCache++ assumes the scheduler is fixed and only the I/O layer changes. **SiloD is the most natural co-citation when we discuss "what FitCache++ doesn't do" (i.e., we don't change the scheduler).**
- URL: https://dl.acm.org/doi/10.1145/3552326.3567499

### DIESEL [Wang et al. ICPP'20]
- **What:** Dataset-based distributed storage and caching for DL training. Solves small-file metadata and shuffled-order rereads.
- **Position:** **Closest in spirit to our dataset-namespacing** (the multi-tenant safety / lifecycle / eviction policy subsection). Cite as inspiration for the "dataset is the unit of caching" design principle, but DIESEL has no cross-job sharing and no multi-tier hierarchy.
- URL: https://dl.acm.org/doi/10.1145/3404397.3404472

### NoPFS [Dryden et al. SC'21]
- **What:** "Clairvoyant prefetching" — uses ML access pattern prediction to prefetch from PFS.
- **Position:** Already cited in IPDPS paper. For TPDS, mention as an **orthogonal optimization** that could be combined with FitCache++ (FitCache provides the cache, NoPFS provides the prefetch policy).

### SHADE [Khan et al. FAST'23]
- **What:** Importance-aware in-memory cache for DDP training; tracks per-sample importance to prioritize hot samples.
- **Position:** Already cited. **SHADE's importance-driven eviction is something we should consider as inspiration for the multi-tenant eviction policy** instead of plain LRU. Can extend our refcount+access-count policy with sample-importance if we want a stronger story.

### Quiver [Kumar & Sivathanu FAST'20]
- **What:** Informed cache that reuses across hyperparameter-tuning jobs by analyzing access pattern similarity.
- **Position:** ⚠️ **Closest existing work to our cross-job motivation.** Quiver explicitly targets HPO sharing. We MUST differentiate carefully:
  - Quiver requires API integration (modified data loader).
  - Quiver focuses on shared *substreams* (same iteration order), not same dataset arbitrarily.
  - Quiver is single-tier (memory only).
  - FitCache++ is POSIX-transparent + multi-tier + arbitrary same-dataset sharing.
- URL: https://www.usenix.org/conference/fast20/presentation/kumar

### CoorDL [Mohan et al. VLDB'21]
- **What:** Cross-job in-memory cache via custom DALI-style API.
- **Position:** Already cited in IPDPS. **This is also direct prior art on cross-job sharing.** Differentiate: API-based, requires code modification, single-tier.

### FanStore [Zhang et al. CoRR'18]
- **What:** Distributed file cache for DL training, scalable I/O for PFS-bound workloads.
- **Position:** Already cited. Single-tier, single-job; baseline-ish.

### DeepFetch [Kong et al. NAS'24]
- **What:** Node-aware greedy fetch for distributed DL caching.
- **Position:** Already cited. Single-tier prefetch, no cross-job.

### iCache [Chen et al. HPCA'23] / HyCache [Jha et al. ATC'25]
- **What:** Importance-sampling-informed cache (iCache); hybrid caching for DNN preprocessing pipelines (HyCache).
- **Position:** Both already cited; both single-tier-ish. HyCache covers preprocessing pipeline angles (orthogonal to our pure I/O).

### RecD [Meta arXiv'22]
- **What:** Deduplication for DL recommendation training infrastructure (end-to-end pipeline).
- **Position:** ⚠️ **Cite as evidence that dataset deduplication / shared caching saves real $$$ in industry.** RecD is for recommendations specifically; we generalize the idea.
- URL: https://arxiv.org/abs/2211.05239

### Cross-job sharing competitors — bottom line

| System | Cross-job? | Multi-tier? | POSIX-transparent? | Year |
|---|---|---|---|---|
| Quiver | ✓ (HPO) | × | × (API) | 2020 |
| CoorDL | ✓ | × | × (API) | 2021 |
| SHADE | partial (DDP) | × | × (API) | 2023 |
| **FitCache++** | **✓ (general)** | **✓ (DRAM/PMem/NVMe)** | **✓ (LD_PRELOAD)** | **2026** |

**This is the table that anchors the related-work positioning of the paper.** The combination of cross-job + multi-tier + POSIX-transparent is genuinely empty in the literature.

---

## 3. Generic multi-tier caching (adjacent)

### Hermes [Kougkas et al. HPDC'18]
- Already cited. Generic heterogeneous-aware buffering. Cross-tier residency tracking is its overhead source. We avoid that overhead via parallel fetch + first-responder.

### Kangaroo [McAllister et al. SOSP'21]
- Already cited. Flash-tiered cache for tiny objects. Different scale (CDN-style); useful for inspiration on cheap metadata.

### Rendezvous Hashing [Thaler & Ravishankar 1996/1998]
- The algorithm we adopt for cross-job-stable routing (the "Routing under variable server-count" subsection of the design doc). Wikipedia + canonical citation. Cite the original 1998 paper (TON).
- URL: https://en.wikipedia.org/wiki/Rendezvous_hashing

### Consistent Hashing [Karger et al. STOC'97]
- Background. Cite when contrasting with HRW.

### Redis / Memcached
- Already cited. KV stores; lack POSIX semantics. Foil for our POSIX-transparent design.

---

## 4. Multi-tenant DL cluster characterization (motivation)

These are the empirical anchors for "cross-job sharing matters in production":

### Microsoft Philly trace [Jeon et al. ATC'19]
- 117K DL jobs, 4-month window, 2017 cluster. Documented job characteristics and queueing delays.
- **Use:** cite for "multi-tenant DL clusters are real" in the introduction.
- URL: https://www.usenix.org/conference/atc19/presentation/jeon
- Trace: https://github.com/msr-fiddle/philly-traces

### Alibaba PAI trace [Weng et al. NSDI'22]
- 6500-GPU production cluster, 2-month trace, 2020. Found that **most tasks are gang-scheduled and recurrent.**
- **Use:** ⚠️ this is the single best citation for "jobs reuse the same dataset." The "executed recurrently" finding is exactly the workload pattern FitCache++ targets. Quote it in the introduction's motivation.
- URL: https://www.usenix.org/system/files/nsdi22-paper-weng.pdf
- Trace: https://github.com/alibaba/clusterdata

### "Dissecting I/O Burstiness in ML Cloud Workloads" [MSST'24]
- Characterization of bursty I/O on Alibaba PAI. Self-similar, non-stationary arrivals.
- **Use:** background for the motivation; helps explain why a multi-tier cache that absorbs bursts is worth it.
- URL: https://www.msstconference.org/MSST-history/2024/Papers/msst24-4.1.pdf

### Multi-tenant scheduling surveys
- "Deep Learning Workload Scheduling in GPU Datacenters" [Gao et al. CSUR'24]: comprehensive survey. Cite once in the background subsection for context.
- ASTRAEA [TPDS'22]: fair DL scheduler for multi-tenant clusters. **Bonus**: this is *in TPDS* — useful citation to establish that the venue cares about multi-tenant DL.
- URL: https://tianweiz07.github.io/Papers/22-TPDS.pdf

---

## 5. PFS-side persistent caching (must differentiate)

### Lustre PCC [Li et al. SC'19] / NVMM-PCC [Li et al. TOS'20]
- ⚠️ **Closest existing concept to our persistent shared cache.** PCC lets clients use local NVMe as a write-back-or-read cache while staying in the Lustre namespace.
- **Modes:** RW-PCC = exclusive read-write on one client's NVMe; RO-PCC = read-only cache distributed across multiple clients' NVMes.
- **Differentiation in the related-work subsection:**
  - PCC requires **Lustre-specific kernel module + HSM integration**; FitCache++ is filesystem-agnostic (works on Lustre, BeeGFS, GPFS).
  - PCC has no concept of *jobs* — caches are tied to Lustre layout locks per file, not to a job lifecycle.
  - PCC's RO-PCC distributed mode is closest to our peer-job lookup, but routing is via Lustre layout metadata (centralized via MDS).
  - PCC has no DRAM/PMem tier orchestration; it's strictly a single-tier (NVMe) cache below the Lustre client.
- URL (LPCC SC'19): https://sc19.supercomputing.org/proceedings/tech_paper/tech_paper_files/pap112s5.pdf
- URL (NVMM-PCC TOS'20): https://dl.acm.org/doi/10.1145/3404190

### Burst Buffers (DataWarp, Frontier's burst buffers)
- Hardware tier between compute and PFS. Used by HVAC implicitly via `BBPATH`.
- **Differentiation:** Burst buffers are a hardware substrate; FitCache++ is the software that uses them intelligently across jobs.

### Data Jockey [Shin et al. IPDPS'19]
- Already cited. Multi-tier storage data management for HPC. Predates the cross-job problem framing we adopt.

---

## 6. CXL / disaggregated memory & FAM (forward-looking)

These belong in the lessons-learned / forward-looking discussion subsection rather than the related-work subsection. Cite to establish "FitCache++ design generalizes to emerging memory fabrics."

### FamFS [Groves, LWN/LSFMM 2024]
- User-space file system for shared fabric-attached memory (FAM/CXL). Multiple hosts can mount the same `fs-dax` filesystem.
- **Position:** ⚠️ The README of FitCache already lists "Work on CXL Memory (FamFS) to support Distributed LLM Training" as future work. Honor that promise: in the discussion subsection, sketch how FitCache++'s peer-fetch source could include a FamFS-backed shared tier.
- URL: https://github.com/cxl-micron-reskit/famfs

### TrainingCXL [HCM'25]
- Persistent memory pooling via CXL for failure-tolerant training of large recommendation models.
- **Position:** Cite alongside FamFS as evidence that CXL/FAM is becoming a real DL training tier. Good for the background subsection's CXL paragraph.
- URL: https://hcm-workshop.github.io/doc/extended-abstract-jhjang.pdf

### Beluga [SIGMOD'25]
- CXL-based memory architecture for LLM KV cache management.
- **Position:** Tangentially relevant; cite once if we discuss inference-side caching as related but out-of-scope.
- URL: https://dl.acm.org/doi/abs/10.1145/3786627

### "Failure Tolerant Training With Persistent Memory Disaggregation Over CXL" [IEEE Micro 2023]
- PMem disaggregation for failure-tolerant DL training.
- **Position:** Aligns directly with our cluster-scoped failure-mode design. Cite in the discussion subsection.

### PIM-is-all-you-need [ASPLOS'25]
- Already cited (ref [52]) in IPDPS. CXL-enabled GPU-free LLM inference. Out of our scope but cite as broader context.

---

## 7. Reference systems for the new workloads in the workload-generalization evaluation

### LLM pretraining I/O
- "Scaling Performance of Large Language Model Pretraining" [arXiv 2509.05258] — TX-GAIN cluster lessons. Cite for "tokenized datasets are pre-processed and cached locally" practice.
- Standard pretraining recipe: tokenize once, then read tokenized chunks repeatedly across many epochs/checkpoints. This is **structurally the same workload pattern** as CosmoFlow/DeepCAM but at LLM scale. Strong story.
- URL: https://arxiv.org/html/2509.05258

### GNN training I/O — BGL [Liu et al. NSDI'23]
- ⚠️ **Direct competitor for the GNN I/O story.** BGL identifies subgraph sampling + feature retrieval as the GNN I/O bottleneck; ~10% GPU utilization typical.
- For the workload-generalization evaluation we'll use MAG240M (175GB raw features). BGL's reported numbers are the natural baseline to beat.
- URL: https://www.usenix.org/conference/nsdi23/presentation/liu-tianfeng

### Open Graph Benchmark MAG240M
- 350GB total, 175GB raw features, memmap'd numpy. The typical workload that exercises feature-fetching I/O hard.
- URL: https://ogb.stanford.edu/docs/lsc/mag240m/

---

## 8. What I still need to read in full (before writing the related-work subsection)

These are papers identified above that are most likely to require careful textual differentiation in the final related-work subsection. Rough priority order:

1. **HVAC + Hash Ring fault-tolerance paper [PDSW @ SC'24]** — newest direct competitor; could affect the cluster-scoped failure-mode design if they did something cleverer than us
2. **Quiver [FAST'20]** — most cited cross-job-sharing prior art; need precise diff
3. **CoorDL [VLDB'21]** — cross-job sharing via API; need precise diff
4. **Lustre PCC papers (SC'19 + TOS'20)** — closest persistent-client-cache prior art
5. **SiloD [EuroSys'23]** — co-design angle we don't take; need to articulate why we don't
6. **Alibaba PAI characterization [NSDI'22]** — read for a specific quote about job recurrence rate to use in the introduction
7. **BGL [NSDI'23]** — GNN baseline
8. **DIESEL [ICPP'20]** — dataset-as-unit precedent
9. **FamFS LWN articles + IEEE conference paper** — for the forward-looking discussion subsection

I'll fetch and digest these in the experiment-plan step and the paper-writing step. Spawning a follow-up agent to read them in parallel is a good way to compress this; flagging that as an option for the next session.

---

## 9. Citations risks / things to be careful about

- **Don't oversell novelty.** Quiver, CoorDL, SHADE all touch cross-job/cross-iteration sharing in different ways. Our novelty is the *combination* (cross-job + multi-tier + POSIX-transparent + decentralized). The related-work positioning has to be precise; reviewers will be alert to this.
- **HVAC fault-tolerance paper (SC'24) is contemporaneous.** Cite it explicitly and run a fault-injection comparison in the sensitivity / ablation / failure-injection evaluation. If we don't, a reviewer will ask.
- **PCC is *real* persistent client caching deployed on Lustre.** Differentiate carefully; it's tempting to under-cite Lustre internals because they're not "DL-specific," but a TPDS reviewer is likely to know PCC.
- **Recurring-job finding from PAI trace is a quote we can't paraphrase loosely.** Read the NSDI'22 paper for the exact percentage / definition before quoting.

---

## 10. Suggested related-work subsection outline (preview)

**Distributed DL and the I/O bottleneck**
  — keep IPDPS content; add 1–2 sentences citing the I/O burstiness work and the Alibaba job-recurrence finding (motivates cross-job sharing).

**Multi-tenancy in DL clusters [NEW]**
  — Philly + PAI traces; recurring jobs; HPO/NAS workloads; 1 short paragraph.

**Memory-tiered data acceleration**
  — keep IPDPS content; add CXL/FAM (FamFS, TrainingCXL) as forward-looking memory tier.

**Limitations of existing systems**
  — extend the IPDPS Table I to include the cross-job dimension and the new systems (HVAC+HashRing, SiloD, DIESEL).

**[optional] Persistent client caches at the FS layer**
  — short subsection on Lustre PCC + Data Jockey, explaining what's filesystem-specific vs. our drop-in approach.

---

End of related-work survey. The experiment plan is next.
