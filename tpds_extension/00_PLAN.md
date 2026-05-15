# TPDS Extension Plan: FitCache → Cross-Job Multi-Tier Caching

**Source paper:** `FitCache_Final_Version.pdf` (IPDPS'26 accepted)
**Target venue:** IEEE Transactions on Parallel and Distributed Systems (TPDS)
**Started:** 2026-05-11

---

## Headline change
The IPDPS paper is single-job. The TPDS version reframes FitCache as a **cluster-level shared caching layer** that survives job boundaries and serves multiple concurrent DL jobs on the same dataset. Real-world motivation: HPO sweeps, NAS, multi-team foundation-model pretraining, repeated benchmarking — all of which run multiple jobs over the same dataset.

## Suggested new title
*"FitCache++: Cross-Job Multi-Tier Caching for Distributed Deep Learning at Scale"*

## TPDS novelty target
~30–40% new technical material. New content must be substantive (not just more experiments on the same design). The extension combines two complementary additions:
- **New system contribution: cross-job cache sharing.** Drives the new design subsections (the cluster-scoped coordination protocol and the multi-tenant safety / lifecycle / eviction policy) and the new cross-job sharing experiments in the evaluation.
- **Broader evaluation.** Real three-tier DRAM+PMem+NVMe hardware run + new workloads (LLM pretraining + GNN), which closes the two-tier extrapolation experiment from the IPDPS paper.

---

## Section-by-section delta vs. IPDPS version

### Introduction (~30% rewrite)
- Add motivation paragraph on multi-tenancy / dataset reuse in DL clusters
- Add "Differences from conference version" footnote citing IPDPS'26
- Refine contributions list to highlight cross-job sharing + three-tier validation

### Background (small additions)
- New subsection: **Multi-tenancy in DL clusters** (cite NAS/HPO papers, Microsoft Philly trace, Alibaba GPU trace)
- Brief CXL / disaggregated memory paragraph

### Design (KEEP existing, ADD two major new subsections)

**Cluster-scoped coordination protocol (NEW subsection)**
- Cluster-level coordination without centralized metadata (extend consistent-hash routing from job-local to cluster-wide)
- Cache lifecycle: caches persist across job boundaries; reference counting keeps hot data alive
- Discovery protocol: how a new job finds existing cached files on neighbor nodes
- Read-only dataset semantics simplify consistency (no invalidation needed)

**Multi-tenant safety, lifecycle, and eviction policy (NEW subsection)**
- Dataset-hash verification (a new job trusts an existing cache only if the underlying file matches)
- Eviction policy under multi-job pressure: extend FIFO with LRU-per-dataset, or "evict caches with no active subscriber first"
- Optional per-allocation namespace if datasets are sensitive

### Evaluation (major expansion)

Existing IPDPS evaluation subsections stay (small refresh of numbers if we re-run).

**Three-tier hardware evaluation (NEW)** — closes the two-tier extrapolation from the IPDPS paper.
- Run on a system with DRAM + PMem + NVMe simultaneously (GPUCLUSTER PMem nodes; investigate Frontier/CXL options)
- Validate the IPDPS extrapolation empirically
- Show capacity vs. latency tradeoff: when does PMem beat NVMe, when does the third tier help?

**Workload-generalization evaluation (NEW)**
- Add ≥2 new workloads beyond CosmoFlow/DeepCAM:
  - **LLM pretraining** (Llama-style on tokenized RedPajama / The Pile slice, or Megatron-LM on C4)
  - **Graph NN** (OGB-LSC MAG240M, or DGL on ogbn-papers100M)
  - Optional: **Vision foundation model** (DINOv2 / MAE on ImageNet-22K)
- Show FitCache works for varied access patterns

**Cross-job sharing experiments (NEW — centerpiece for the cluster-scoped coordination protocol)**
- *Concurrent jobs:* 2–4 jobs on same dataset, cache hit rate vs. independent caching
- *Sequential reuse:* one job finishes, the next starts on the same data, cold-start elimination
- *Multi-tenant pressure:* 8+ jobs, mixed datasets, eviction behavior + fairness
- *Scale test:* same on 1024+ Frontier GPUs

**Sensitivity, ablation, and failure-injection evaluation (NEW)**
- Cache-size sweep, server-count sweep (extend the IPDPS scale studies)
- Hash function choice (consistent vs. rendezvous)
- Failure injection: kill a server mid-training, recovery cost

### Discussion / Lessons Learned (NEW)
- When NOT to use FitCache (small datasets, single-epoch jobs)
- Operational lessons from production deployment
- Forward look: CXL / disaggregated memory integration

### Conclusion (light refresh)

---

## Code work scope (~3,800 LOC starting point)

| New feature | Files likely touched | Est. added LOC |
|---|---|---|
| Cross-job cache discovery (cluster-wide routing) | `fitcache_comm_*.cpp`, `fitcache_server.cpp` | ~600 |
| Reference counting + lifecycle | `fitcache_cache_policy.cpp` | ~300 |
| Dataset-hash verification | new `fitcache_dataset_id.cpp` | ~200 |
| Multi-tenant eviction policy | `fitcache_cache_policy.cpp` | ~250 |
| Failure recovery / health checks | `fitcache_comm_server.cpp` | ~300 |

Total: ~1,600 new LOC, ~40% growth — aligned with TPDS novelty expectations.

---

## Workstream order

1. **Read the current code**, report architecture findings → grounds the design in reality
2. **Cross-job design doc** → protocol for cross-job discovery, lifecycle, safety, eviction
3. **Related-work survey** for cross-job caching, multi-tenant DL, dataset reuse
4. **Evaluation plan** → exact configs, baselines, plots; depends on the design from step 2
5. **Implementation** of the cluster-scoped coordination protocol + multi-tenant safety/lifecycle/eviction policy
6. **Run experiments** (three-tier hardware eval, workload-generalization eval, cross-job sharing experiments, sensitivity/ablation/failure-injection eval)
7. **Write paper** sections in parallel with experiments

Working docs land in this folder:
- `00_PLAN.md` (this file)
- `01_code_architecture.md` (step 1 output)
- `02_design_cross_job.md` (step 2 output)
- `03_related_work.md` (step 3 output)
- `04_experiment_plan.md` (step 4 output)
- `05_implementation_notes.md` (engineering progress tracker; updated as mechanisms land)
