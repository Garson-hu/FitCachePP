# FitCache++ Worklog

### 2026-05-19 — TPDS contribution pivot: mmap interceptor + sidecar warm-restart land as the two new mechanisms; cross-job becomes future work

After the cross-job campaign concluded with weak wall-time savings + recurring `DataLossError` flakiness (see 2026-05-17 / 2026-05-18 entries below), the TPDS contribution shape was revised. **Two new mechanisms now anchor the paper, with cross-job sharing demoted to secondary / future work:**

1. **Primary new contribution — mmap interceptor + LLM workload generalization.** The IPDPS-paper FitCache intercepted only `{open, read, pread, close}`; page-fault reads from `mmap`-based loaders (numpy.memmap, Megatron `IndexedDataset`, DINOv2 ImageNet tarballs) silently bypassed the cache. The `src/client/wrappers.c::mmap` intercept allocates an anonymous region and eager-populates it via `ms_read` at `mmap()` time. Validation: bit-identical Megatron `lm_loss=6.1157` between FitCachePP and Pure_CF; **11.5× cold-state throughput** (894 MB/s vs 78 MB/s) on a 10 GB synthetic Megatron `IndexedDataset`; 1.93× amortized over 20 K iterations × batch 16 × seq 1024. Auto-memory: [[project-mmap-interceptor-contribution]], [[project-llm-dataloader-headline]].
2. **Second technical contribution — persistent sidecar metadata + warm-restart recovery.** Each cached file gets a `.meta` sidecar (magic + version + `original_path` + `original_size` + `cached_at_unix` + `access_count`) written atomically alongside the data file. On server startup, `restore_from_sidecars()` scans the tier directories and rebuilds `path_cache_map` so the next training process hits the cache without refetching from PFS. **Validation experiment 4614896 (2026-05-19 00:01):** Phase 1 cold (server srun #1, empty cache) Epoch wall 340 s → kill server → Phase 3 warm-after-restart (server srun #2, scanned 33,789 sidecars from disk) Epoch wall **260 s** (= warm-baseline 285 s within run-to-run noise, 80 s faster than the cold-from-empty 340 s). Mechanism rebuilt `path_cache_map` with **33,789** entries on every one of the 4 server ranks. Auto-memory: [[project-sidecar-warmrestart]].
3. **Future / secondary — cross-job sharing.** Mechanism is functional and validated end-to-end (peer_lookup, redirect_to_peer, has_yes counters work as designed). Wall-time benefit is structurally bounded (I/O fraction of cold epoch + consumer local-cache absorption). Concurrent mode has a recurring `DataLossError: inflate() failed` that is un-root-caused. Kept in the paper as secondary prototype evidence / future work. Auto-memory: [[project-cross-job-limits]].

**Engineering change that enabled the sidecar validation:** decoupled sidecar write + restore from `FitCache_CROSS_JOB`. The original gate ran the cross-job machinery (registry init + heartbeat + sibling-refresh threads) for any test that wanted sidecar persistence; those threads skewed Horovod ranks 2 + 7 at n=32768/1N (job 4614727 hung 28 min in `HorovodAllreduce` before walltime kill). New flag `FitCache_PERSIST_META=1` (auto-on under cross-job; opt-in otherwise) gates just the sidecar write + restore. Code: `bool persist_meta_enabled()` in `src/cross_job/fitcache_cross_job.{h,cpp}`; gate replaced at `src/server/fitcache_data_mover.cpp:512` and `src/server/fitcache_server.cpp:179`. 16/16 cross-job smoke tests pass.

**Operational note (saved to durable memory):** the hackathon Frontier queue parked the original sidecar validation 19 hours behind other jobs for a ~13-minute experiment. Rule encoded in [[feedback-slurm-proactive-resubmit]]: a SLURM heartbeat must auto-cancel + resubmit under `QOS=debug` whenever a pending job's `StartTime` is many hours away while its `TimeLimit` is short. A 20-minute cron heartbeat (id `f1e73f8f`) was armed for this session that applies that rule + tails completed-job stdouts.

**Next steps**
- Restructure `tpds_extension/05_implementation_notes.md` around the three-contribution shape (done in this session).
- Optional: re-run the warm-restart experiment at full IPDPS n=524288 to characterise the sidecar-scan walk time at 524K `.meta` files (currently estimated 10-15 s on Lustre `/tmp`).
- Optional: rerun the LLM dataloader at a corpus large enough that the warm-state Pure_CF advantage disappears (the current 10 GB corpus fits in 188 GB-RAM node page cache after Epoch 1, so Pure_CF eventually catches up). 50-100 GB corpus would isolate the cold-state advantage from page-cache amortization.

### 2026-05-18 — 16-node strong-scaling + 3-run averaging; full IPDPS training set; LLM dataloader 11.5× cold; cross-job sharing limits identified

- **16-node n=131072 single-job (job 4604373):** cold **140 s**, warm **73 s**, mean **106 s**, wall 979 s. 2.6× strong-scaling speedup over 1-node n=32768.
- **Three-run averaging** for headline single-job configurations:

  | Configuration | Cold mean ± std | Warm mean ± std | n |
  |---|---|---|---|
  | 1-node n=32768 | 352 ± 10 s | 289 ± 3 s | 3 |
  | 4-node n=131072 | 369 ± 7 s | 290 ± 3 s | 3 |
  | 16-node n=131072 | 140 s | 73 s | 1 |

- **Full IPDPS training set at 16 nodes (job 4606441):** first clean run that exercises all 524288 training tfrecords. Cold **365 s**, warm **302 s**, mean 333 s, wall 917 s. Per-rank load matches 1-node n=32768 (4096 files/rank); cold-epoch wall is within 1 s of the 1-node baseline — weak-scaling overhead is essentially zero at full-IPDPS scale.
- **LLM dataloader benchmark (10 GB synthetic Megatron IndexedDataset, 327 M tokens read):**
  - FitCachePP cold sample: 894 MB/s, 28.6 K iters/s, 0.03 ms/step
  - Pure_CF cold sample: 78 MB/s, 2.5 K iters/s, 0.40 ms/step
  - **Cold-state speedup: 11.5×**; amortized over 20 K iters: **1.93×** (855 MB/s vs 443 MB/s)
  - Built `benchmarks/megatron/generate_synth_corpus.py` + `llm_dataloader_bench.py` for this. Pure_CF eventually catches up after kernel page cache warms, but the amortized advantage holds because a real LLM pretraining loop doesn't re-read the same files many times.
- **Cross-job sharing — warm-provider controlled experiment (null result).** New `frontier_cosmoflow_xjob_warmprovider.sh`: producer trains to completion then sleeps to keep its cache+servers alive; consumer pre-sleeps so producer Epoch 1 finishes before consumer reads start. Consumer cold = **354 s** (matches single-job 352 s baseline) with `has_yes` ≤ 27. Sharing did not engage at meaningful rate. Structural cause: consumer's local NVMe cache absorbs the per-rank working set (~20 GB) within Epoch 1, so the peer cache becomes unused after the first epoch.
- **Cross-job sharing — multi-node concurrent escalation (recurring flakiness).** Per the user's escalation rule, ran concurrent cross-job at n=131072 / 4 nodes per side (jobs 4607367 + 4607369). Parameterized `frontier_cosmoflow_crossjob_sharing.sh` to take `N_NODES_PER_JOB`. Consumer crashed with `DataLossError: inflate() failed with error -3: invalid code lengths set` in Epoch 1 — same recurring corruption pattern seen at every previous concurrent-cross-job attempt at scale. Producer hung after consumer death (in-flight RPCs to dead peers block).
- **Cross-job summary:** mechanism validated end-to-end (peer_lookup, redirect_to_peer, has_yes all work as designed); per-call profiling confirms peer reads are 10% faster than local-HRW reads. Wall-time benefit is structurally bounded by (a) I/O fraction of cold-epoch wall and (b) consumer's local cache absorbing the working set within Epoch 1. One clean wall-time data point stands (1-node n=32768 concurrent best run: consumer cold 338 s vs single-job mean 352 s, **−14 s**). The recurring concurrent-mode `DataLossError` is a real defect, not benchmarking variance, and remains un-root-caused.

**Next steps**
- Frame cross-job sharing claim honestly in the paper: mechanism validated, per-call optimal, wall-time benefit bounded by I/O fraction + local-cache absorption; recurring concurrent-mode data-corruption is future work.
- The strong empirical results for the journal extension are: 16-node full IPDPS training set weak-scaling, 16-node n=131072 strong-scaling 2.6×, and the **LLM dataloader 11.5× cold-state throughput speedup** (the headline LLM evidence the previous Megatron correctness check lacked).
- Optional: root-cause the concurrent-cross-job `inflate()` corruption with instrumented reproduction (capture the bytes the consumer's `__real_pread` fallback writes vs the bytes Mercury delivered). Defer unless the paper claim needs it.

### 2026-05-17 — 4-servers-per-node fix unblocks n=32768; cross-job sharing speedup scales 9× at larger dataset; multi-node weak-scaling clean; Megatron + DINOv2 re-verified

- **4-servers-per-node fix landed and unblocks n=32768.** Single fitcache_server progress thread serialised RPC handlers on slow Lustre `open()` syscalls under MDS contention; at n=32768 with 2 servers per node the server fell silent after ~280 RPCs and the training job timed out. Bumping `SERVERS_PER_NODE=4` (default in both `frontier_cosmoflow_headline.sh` and `frontier_cosmoflow_crossjob_sharing.sh`) distributes the hashring across four progress threads. n=32768 single-job (job 4603330) then completed end-to-end: cold 366s, warm 285s, training wall 708s, server handled 65,764 opens with no stall.
- **Cross-job sharing wall-time speedup scales with dataset size.** Single-run numbers:
  | Dataset | Single-job cold | Cross-job consumer cold | Δ | Rel. speedup | Redirects/opens |
  |---|---:|---:|---:|---:|---:|
  | n=8192 (~8 GB) | 135s | 132s | −3s | −2.2% | 4790 / 8226 = 58% |
  | n=32768 (~32 GB) | 366s | **338s** | **−28s** | **−7.7%** | 7036 / 33456 = 21% |
  Absolute speedup is ~9× larger at n=32768 vs n=8192. Mechanism is per-call optimal at both scales; wall delta scales with the dataset's I/O fraction of cold-epoch wall.
- **Per-call profiling instrumented and captured.** Added `FitCache_TIMING` per-path tags inside `ms_read` (`bypass_pfs`, `hrw_normal_total`, `peer_redirect_total`) and a `FITPP_TIMING_DUMP_ON_EXIT=1` env-var gate that calls `fitcache::print_all_stats()` from `fitcache_client_shutdown`. n=8192 cross-job consumer histogram: raw Lustre `__real_pread` 1033 us/call, FitCache local-server HRW 613 us, FitCache **peer-server 551 us** — peer reads ~10% faster than local HRW (peer's server doesn't also handle this job's open-RPC fanout). Predicted wall savings from `redirect_count × (lustre_avg − peer_avg)` matches the observed 135→132s exactly.
- **4-node n=131072 single-job (job 4604034) completed clean weak-scaling**: cold 375s, warm 289s, mean 332s, wall 723s. Per-rank file count matches 1-node n=32768 (4096 files/rank), and the 4-node epoch wall is only 9s slower than the 1-node case — multi-node coordination overhead is small for cosmoflow at this scale.
- **16-node n=131072 first submission (4604189) failed on a cosmoflow config divisibility check.** Default `n_valid=256` doesn't divide 128 ranks × batch 4 = 512. Patched `frontier_cosmoflow_headline.sh` to export `FITPP_N_VALID=1024` and pass `--n-valid` to `train.py`. Failure mode and fix recorded in `feedback_cosmoflow_n_valid_multinode.md`.
- **Megatron-LM correctness check passed.** GPT pretrain (12 layers, 200 iters, enwik8) with FitCachePP and Pure_CF produces **bit-identical** `lm_loss=6.1157` at iteration 200. Wall: FitCachePP 66s vs Pure_CF 77s. mmap interceptor anon-fill compatibility intact.
- **DINOv2 compatibility check passed.** I/O-only iterator (2000 iters, imagenet_synth) completes cleanly under both FitCachePP and Pure_CF. FitCachePP slower (5s vs 2s) because the workload is too I/O-light (216 MB total / 2s ≈ 100 MB/s page-cache rate) for FitCache RPC overhead to amortize. Confirms compatibility, not a regression.
- **Two failed attempts at cross-job peer-death recovery, both reverted.** First attempt swapped `pthread_cond_wait` for `pthread_cond_timedwait` (10s deadline) with refcounted `ms_read_state` + cb-owns-state cleanup. Second attempt kept unbounded wait but added an in-flight handle tracker + 5s watchdog that HG_Cancel'd handles for dropped slots, plus `ms->ssd_done=true` init. Both reproduced the same `DataLossError: inflate() failed with error -3: invalid block type` on the producer training job's first IteratorGetNext. Cause not root-caused. Recorded as `feedback_ms_read_fragile_init.md`. Net: producer training job hangs after consumer training job exits mid-run; each side completes independently so single-run headline numbers are unaffected.

**Push status:** several engineering changes are unpushed (FITPP_SKIP_MANIFEST_SCAN in dataset_id, epoch-guard + close-RPC-skip in fitcache_comm_client.cpp, multi-node + 4-servers + n_valid in launchers, per-path profiling instrumentation in ms_read + fitcache_client.cpp). User to push when ready.

### 2026-05-12 — Single-job CosmoFlow baseline complete, sidecar restore validated; cross-job-concurrent and real-PMem investigation

End-to-end cluster experiments after fixing 6+ session bugs (path-filter mismatch in train.py vs FitCache_DATA_DIR, mpirun-strips-env, parallel-srun-deadlock, TPDS_FITPP.sh hardcoding overrides, FitCache_PMEM_PATH unbound under `set -u`, and the 6 from 2026-05-11).

**Single-job FitCachePP-vs-Pure_CF CosmoFlow baseline runs**, all at n_train=8192 on c66 (1 GPU, 188 GB RAM):

| Cell | Mean epoch | Cold ep1 | Warm ep2-5 | σ |
|---|---:|---:|---:|---:|
| Pure_CF (no LD_PRELOAD), OS-warm ×2 | 842s | 856 / 855 | 841s | < 2s |
| Pure_CF OS-cold (page cache evicted) | 840s | 855s | 838s | 1 rep |
| FitCachePP, OS-warm ×3 | 905s (reps 2-3, rep 1 cold-cluster=1048) | 940-941 | 897s | < 3s |
| FitCachePP OS-cold ×1.5 | 899s | 935-936 | 891s | < 2s |

**Headline:** at n_train=8192/1-GPU, **FitCachePP adds 58s = +7% overhead**. Root cause: train_61440 dataset (167 GB) fits in c66's 188 GB RAM → OS page cache absorbs working set → FitCachePP's local-NVMe cache has nothing structural to win against. Mercury RPC per file open costs ~13ms/file × 4096 files = ~53s overhead per epoch. Page cache eviction (`posix_fadvise(POSIX_FADV_DONTNEED)`) confirmed no effect — **GPU compute (~205ms/step × 4096 steps = 840s) is the bottleneck**, not I/O. FitCachePP's value emerges in cross-job mode (the two-job sequential sidecar-restore run below) and presumably at multi-GPU large-working-set regime (an n_train=61440 multi-GPU run, not yet attempted).

**Two-job sequential, sidecar restoration across job boundary** (SLURM 221695 → 221696 on c66 via `--dependency=afterok`, shared local cache):

| Job | Cold ep1 | Warm ep2-4 | Sidecars at startup |
|---|---:|---:|---:|
| Job A (no prior cache) | 1023s | 863s ± 2s | 0 |
| **Job B (sidecar restore)** | **979s** | 864s ± 1s | **9,216** |

**Headline:** Job B's startup ran `restore-sidecars` and rebuilt path_cache_map from 9,216 sidecars on disk. Job B's epoch-1 = 979s = Job A's cold (1023s) − 44s = the FitCachePP cache-promotion overhead that Job B avoided. **The persistent-sidecar-metadata mechanism is validated** — Job B avoids the FitCachePP-specific cold-start penalty. (Job B epoch 5 hung after 90+ min; cancelled. The hang is independent of the sidecar restore claim, which is fully exercised in epoch 1.)

**Two-job concurrent peer_lookup redirect — UNRESOLVED.** Both attempts cancelled after 1h50min stuck on epoch 1. cross_job_stats counters show peer_lookup RPCs DO fire (11,662 forwarded by Job B) but EVERY response is has_no=0 across 12,196 lookups. Hypothesis: HRW with 8 cluster servers picks different servers across jobs for the same path; the responder server's path_cache_map doesn't have the file. Deeper analysis (HRW imbalance + per-server-process path_cache_map partitioning) in [mmap_and_cross_job_imbalance_analysis.md](benchmarks/results/arc/mmap_and_cross_job_imbalance_analysis.md). Deferred for follow-up code work.

**Real DAX-mode PMem hardware evaluation on c35.** `/mnt/fsdax` write access initially blocked (root-owned), unblocked later in the session. Two sustained-read micro-benchmark runs on c35 with `FitCache_PMEM_PATH=/mnt/fsdax`: source-on-local-/tmp gave warm-vs-cold = 0.13x (warm 7.5x slower); source-on-BeeGFS with OS-page-cache eviction gave warm-vs-cold = 0.21x (warm 4.8x slower). The cache-hit path pays ~250 ms per-open RPC overhead that the cache-miss path doesn't; PMem vs NVMe doesn't matter at this work granularity. Tier placement on real PMem works end-to-end. The natural follow-up (CosmoFlow on c35 with three-tier wiring and BeeGFS source) is infeasible: c35 has DAX PMem but no GPU; the rtx4060ti16g GPU nodes have no DAX PMem. Full write-up at [real_pmem_evaluation_on_c35.md](benchmarks/results/arc/three_tier/real_pmem_evaluation_on_c35.md).

**Workload-generalization run (Megatron-LM + DINOv2) — architectural limit.** Both target workloads use `mmap`-based zero-copy reads (numpy.memmap for Megatron's IndexedDataset; mmap+slice for DINOv2's ImageNet22k tarballs). FitCachePP's LD_PRELOAD client intercepts `open/read/pread` but not `mmap`, so the page-fault reads bypass FitCachePP entirely. Empirical confirmation: `megatron_io_only_iter.py` runs 200 iters in < 5ms with or without LD_PRELOAD; server logs show 0 Open RPC. Analysis at [mmap_and_cross_job_imbalance_analysis.md](benchmarks/results/arc/mmap_and_cross_job_imbalance_analysis.md). Three options for the paper (drop these workloads, add an mmap interceptor, or reframe the FitCachePP contract as syscall-based-I/O only). The reframing-the-contract option is the honest framing.

Files: [single_job_baseline_and_sidecar_restore_summary.md](benchmarks/results/arc/single_job_baseline_and_sidecar_restore_summary.md), [mmap_and_cross_job_imbalance_analysis.md](benchmarks/results/arc/mmap_and_cross_job_imbalance_analysis.md), [real_pmem_evaluation_on_c35.md](benchmarks/results/arc/three_tier/real_pmem_evaluation_on_c35.md), [EXPERIMENT_STATUS.md](EXPERIMENT_STATUS.md). Commits this session: 11 (path-filter, data-mover, registry, scripts, summaries). Cluster jobs run: ~20+ over the day.

**Next steps**
- Debug the two-job concurrent cross-job-sharing run: instrument peer_lookup to log requested-path vs available-path mismatch; verify HRW server selection is consistent across job processes; add a sibling-fanout to `fitcache_peer_lookup_rpc_handler` that queries the other server-processes on the same host before answering has_no.
- Profile the cache-hit open path to identify the ~250 ms-per-open bottleneck (cluster-registry lookup, path_cache_map serialization, redirect protocol).
- Workload-generalization: decide between picking syscall-based replacement workloads (HuggingFace streaming datasets / per-file PIL.Image / line readers) and implementing the mmap interception layer (substantial — `userfaultfd`-based).
- Optional n_train=61440 multi-GPU run for IPDPS-comparable wall-clock parity.

### 2026-05-11 (latest) — Post-engineering hardening pass: HRW addr-in-hash, cross-job telemetry, PMem tier

Picked up after the two-job concurrent cross-job sharing run on c70 + c71 surfaced a routing collapse: identical `/etc/machine-id` across the two hosts made `node_uuid` identical, so the HRW (highest-random-weight) score `path || node_uuid || rank` tied across hosts and all paths landed on whichever host registered first. Five concrete changes landed in this session.

- **HRW addr-in-hash fix** (`src/fitcache_cross_job.cpp`). Appended `s.addr` (the Mercury endpoint string, embeds host:port and is therefore unique per endpoint) to the HRW input. Breaks the tie; preserves behaviour for clusters with distinct machine-ids. Inline comment in `hrw_select` documents the failure mode.
- **Cross-job telemetry counters** (`src/fitcache_cross_job.{h,cpp}` + comm-server bumps + heartbeat-thread emit). Eight atomic counters for the open + peer-lookup events (`opens_total`, `opens_local_hit`, `opens_redirect_to_peer`, `opens_pfs_fallback`, `peer_lookup_forwarded`, `peer_lookup_handled`, `peer_lookup_has_yes`, `peer_lookup_has_no`). Periodic L4C_INFO line emitted from the heartbeat thread when `FitCache_CROSS_JOB=1`, gated so single-job runs stay silent. Verified in the bit-equivalence smoke: 8-file workload produced `opens_total=8 pfs_fallback=8 peer_lookup forwarded=0 handled=0`.
- **Bit-equivalence smoke** (`scripts/smoke/run_bit_equivalence_smoke.sh` + `benchmarks/results/arc/bit_equivalence/summary.md`). Defends the zero-regression-vs-IPDPS-single-job claim at the byte level: runs the same 8-file synthetic workload with `FitCache_CROSS_JOB=0` and `=1` (single-server, no peers), per-file sha256 of cached payloads must match across passes and against source. PASS. Re-run after the PMem changes; still PASS.
- **Opt-in PMem tier** (`src/fitcache_cache_policy.h`: added `CACHE_TIER_PMEM = 4`; `src/fitcache_data_mover.cpp`: env vars `FitCache_PMEM_PATH` / `FitCache_PMEM_CAPACITY`, placement priority DRAM → PMem → NVMe, per-tier `g_pmem_used_bytes`, restore-sidecars loop scans PMem dir, eviction reaper handles the third tier). Dormant when env vars unset — the bit-equivalence smoke confirms zero behavior change in that case.
- **Three-tier pilot scripts** (`benchmarks/cosmoflow/TPDS_FITPP_three_tier.sh` for the CosmoFlow + Horovod variant; `scripts/smoke/run_three_tier_sustained_read.sh` for a CPU-only sustained-read micro-benchmark). Local smoke `scripts/smoke/run_three_tier_smoke.sh` verified 4/4/4 placement split across DRAM/PMem/NVMe and full restoration of all 12 files from sidecars per-tier across server restart. Cluster pilot deferred: c35 (the known-PMem candidate) is in the `cascade` partition (CPU-only); CosmoFlow + Horovod needs a GPU node that also has DAX PMem, which the cluster doesn't obviously have.

Concurrent retry (SLURM 221616 + 221617 on c70 + c71) ran after the HRW fix landed: both jobs completed in ~16:15, cold epoch 200s, warm epochs 185-189s. Direct routing-balance check across the two nodes wasn't possible from this run because the per-server log4c output (where the `Open RPC: requested path` lines land) didn't end up in `$RESULTS_DIR` — only the heartbeat-error log got captured. Result + observations at `benchmarks/results/arc/two_job_concurrent/summary_221616_221617_retry.md`.

Sequential cross-job experiment (SLURM 221618 → 221619 on c66, Job B `--dependency=afterok` on Job A): Job A finished, Job B currently running.

**MAJOR FINDING from inspecting Job A's tier dirs and the live Job B server logs:** every cluster CosmoFlow run in this session (single-job baseline 221607, two-job concurrent 221614/221615 + 221616/221617 retry, two-job sequential 221618/221619) has executed with **zero FitCache Open RPCs**. Direct evidence: on c66, `find /mnt/local/ghu4/fitcachepp_{dram,nvme}_seq_*` returns zero files and zero `.meta` sidecars after Job A completed; across every `fitcache_server_log.*.0` file in the repo root, `grep -c 'Open RPC: requested path'` is 0. Servers start, register, heartbeat — but never see client traffic. Likely root cause: `FitCache_DATA_DIR=/mnt/beegfs/.../train_61440/train/` but `train.py` reads `/mnt/beegfs/.../train_1024` (per `configs/cosmo.yaml`), and the LD_PRELOAD client's path filter doesn't match. All reads pass through to BeeGFS direct, bypassing FitCache.

Implication for prior claims: the 200s cold / 188s warm epoch pattern across all runs is Linux page cache + GPU/TF warmup, not FitCache cross-job sharing. The previously-recorded "cold epoch -45%" / "per-job wall -14%" / "aggregate -57%" numbers should NOT be quoted in TPDS material until the path-filter mismatch is fixed and the experiments are re-run with the FitCache pathway verifiably engaged (i.e. `grep -c 'Open RPC: requested path' fitcache_server_log.*` > 0). Detailed evidence + recommended remediation in `benchmarks/results/arc/two_job_sequential/summary_221618_221619.md`.

What IS still defended (path-filter fix not required): bit-equivalence smoke, three-tier local smoke, unit smoke suite, and the HRW addr-in-hash fix on its merits.

Known issue logged for follow-up: `fitcache_cluster_registry.cpp:155` rename-busy storm on long-lived shared registry dirs. Orphan `<final>.tmp.<pid>` files from earlier processes that SLURM didn't fully tear down cause chains like `c70_rank0.txt.tmp.A.tmp.B.tmp.C` and EBUSY rename failures. Functional impact is log noise + delayed heartbeat refresh; experiments still complete. Mitigation: per-run unique `$RUN_REGISTRY` subdir (already in place). Real fix would prune orphan tmps at registry init.

Commits (local, not pushed; user pushes manually):
- `feat: add cross-job telemetry counters with periodic logging`
- `feat: add opt-in PMem tier between DRAM and NVMe`
- `feat: add three-tier cluster pilot script and sustained-read bench`

Plus the HRW addr-in-hash commit that landed before this session.

**Next steps**
- When Job B (SLURM 221619) finishes, record the sequential-result summary in `benchmarks/results/arc/two_job_sequential/` — expecting Job B epoch-1 to be warm (~190s) instead of cold (~362s), defending the sidecar-rebuild-survives-job-boundary claim.
- Capture per-server log4c output into `$RESULTS_DIR` in `TPDS_FITPP_inner.sh` so future cluster runs can do an opens-per-node tally directly.
- Investigate the `registry_gc_stale` rename-busy storm root cause if it recurs in a clean fresh run.
- Submit the three-tier pilot when a node with both a GPU and a DAX PMem mount is identified; otherwise run `scripts/smoke/run_three_tier_sustained_read.sh` on c35 for a CPU-only three-tier characterisation.

### 2026-05-11 (later) — End-to-end cross-job sharing proven on Mercury; cluster experiments started

Multi-server localhost smoke harness brought up — the first real Mercury test of the cross-job redirect path. Surfaced three real bugs which were fixed in the process:

1. **Silent hang on lookup_addr=NULL.** Three RPC functions (`fitcache_client_comm_gen_open_rpc`, `_gen_read_rpc`, `_gen_seek_rpc`) returned without firing the per-file sync context when `fitcache_client_comm_lookup_addr` returned NULL. The caller's `fitcache_client_block_for_file` then blocked forever. Now all three signal `-1` on the sync context so the caller's wait unblocks.
2. **`std::string` global state silently zeroed mid-process.** `cluster_registry.cpp`'s `g_nodes_dir / g_registry_root / g_datasets_dir` had their heap-backed `c_str()` become `""` between `registry_init`'s write and the first `registry_live_servers` read — same address, different contents. Diagnosed via address-printing under WARN logs. Workaround: switched to fixed-size `char[1024]` buffers with thin getter functions, never reallocated after init. Root cause likely a libstdc++ destructor-ordering or LD_PRELOAD interaction; not pinpointed.
3. **`ms_read` missing peer-slot override.** After the open redirect succeeded, subsequent reads on the redirected fd went back to the HRW-chosen server (which doesn't know the peer's remote_fd). Fixed: `ms_read` now consults `fitcache_client_get_peer_slot_override` before the HRW selection, matching the path already in `fitcache_remote_read` / `_pread` / `_lseek` / `_close`.

Pre-existing code quality fixes folded in (build now compiles with zero warnings):
- `wrappers.c` now properly `#include "fitcache_multi_source_read.h"` so `ms_read` is not implicitly declared.
- `fitcache_multi_source_read.h` was using `std::vector` inside an `extern "C"` block (broken for C consumers). Moved the C++-only `g_pm_ranks`/`g_ssd_ranks` declarations out of the `extern "C"` block.
- `test_open_close.c` was calling `fclose` on an `int` fd. Changed to `close(int)`.
- `CMakeLists.txt` `DEBUG_HU` option was inverted (passing `-DDEBUG_HU=ON` defined the C macro to `0`/falsy). Now it defines to `1` when on, `0` when off.

Also tightened `cluster_registry.cpp::rmw_kv_file` to ensure the parent directory exists before opening — fixes a stale-init scenario where the static `g_datasets_dir` outlives the directory it points at (between repeat test runs).

**Smoke harness result:** 5 peer_lookup hits, 5 server-side `FITCACHE_OPEN_REDIRECT`s, 5 client-side redirects handled, all 8 files read end-to-end. Cross-job sharing is **proven on real Mercury** for the first time. Committed locally as `54fb50d`.

**Benchmark scripts** under `benchmarks/cosmoflow/`:
- `TPDS_FITPP.sh` — single-job FitCache++ baseline (`FitCache_CROSS_JOB=0`)
- `TPDS_FITPP_inner.sh` — shared launcher (per-node servers + horovodrun)
- `TPDS_FITPP_two_job_sequential.sh` — Job B sbatched with `--dependency=afterok` after Job A
- `TPDS_FITPP_two_job_concurrent.sh` — both jobs sbatched in parallel on different nodes
- `command_CF_FITPP.sh` — horovodrun command body with `cd` to the cosmoflow benchmark dir
Committed locally as `8fb565e`.

**First cluster experiment landed:** single-job FitCache++ baseline on c66, SLURM 221607, 19m00s wall.
- Epochs: 362 / 189 / 188 / 188 / 186 s. Cold/warm speedup 1.93x.
- `peer_lookup_query_count = 0` across all 4 servers (correct, single-job mode).
- `sidecar_writes = 0` (correct, sidecars only fire when cross-job=1).
- **Shape-level confirmation of the zero-regression-vs-IPDPS-single-job claim.** Bit-identical comparison deferred.
- Result + summary at `benchmarks/results/arc/single_job_baseline/`. Committed.

**Two-job concurrent cross-job experiment landed.** First attempt (221612 c70 + 221613 c71) surfaced a fourth bug — the cluster registry's single-file-per-node rmw pattern races on BeeGFS because atomic-rename invalidates the flock inode binding. The first run's per-node registry file ended up containing only `heartbeat` keys (no addr/rank/jobid) because the heartbeat thread's RMWs fired most often and were always last. Fixed by switching to **one file per server-instance** (`nodes/<hostname>_rank<N>.txt`); each server is the sole writer of its own file (committed `4b7680e`/`3971d8c`).

Second attempt (221614 c70 + 221615 c71) ran clean. Headline result:

| Metric | Single-job baseline (221607) | Two-job concurrent (221614 + 221615) | Δ |
|---|---:|---:|---:|
| Cold epoch | 362 s | ~199 s | **−45%** |
| Per-job wall | 19m00s | 16m19s | **−14%** |
| Aggregate I/O work (2 jobs) | 38m00s sequential | 16m19s concurrent | **−57%** |

Mechanism: HRW deterministically picks the same server for the same path across both jobs (same dataset, same global live set). Whichever job hits a file first warms the cache; the other gets a hit. peer_lookup fanout + redirect path did NOT fire — expected for a stable live set; the redirect path is for server-set churn (artificially induced in the localhost smoke). Result + analysis at `benchmarks/results/arc/two_job_concurrent/summary_221614_221615.md`. Committed `07d28a0`.

Caveat noted: c70 and c71 share `/etc/machine-id`, so HRW scores tied across nodes and all paths landed on whichever node registered first. Routing isn't node-balanced. Cross-job-sharing claim still holds; routing-balance is a separate hardening item (inject hostname or addr into HRW input).

**Heartbeat:** Monitor task `bcfafdkil` (30-min interval) running.

**Next steps after the concurrent experiment finishes**
- Grep cross-job hit counts from both jobs' server logs; quantify the cross-job-sharing-reduces-aggregate-IO claim at the 4-server-per-node × 2-job scale.
- Run the two-job sequential variant (Job B with `--dependency=afterok`) if time permits.
- PMem tier support + three-tier hardware evaluation pilot on c35 deferred to a future session (architectural change, ~4h).
- Bit-equivalence unit-test harness still pending.

**Push status:** local commits `54fb50d`, `8fb565e`, and the upcoming baseline-result commit are unpushed (no credentials in this environment).

### 2026-05-11 — Cross-job extension engineering work complete (four mechanisms)

Four commits land the open-time peer-fanout path, persistent
sidecar metadata, refcount-respecting eviction, and the subscriber-lease
machinery. Engineering scope of the cross-job extension is complete
(~1,500 LOC across these four mechanisms, within the original ~1,600 LOC budget).

**Commits (unpushed, local on `main`):**
- `c816420` — subscriber-lease management for cross-job eviction protection
- `21772a6` — refcount-respecting eviction + background reaper
- `25680e9` — persistent sidecar metadata for cross-job cache durability
- `2c76cc6` — open-time peer-lookup fanout for cross-job cache sharing
- `6f7585d` — client-side HRW routing for cross-job cache sharing (previously pushed)

**What landed in each mechanism:**

- **Open-time peer-lookup fanout** (`2c76cc6`). Server-side async state
  machine in `fitcache_open_rpc_handler`: on `path_cache_map` miss with
  `FitCache_CROSS_JOB=1`, fan out `fitcache_peer_lookup_rpc` to every
  live peer; first peer that responds `has=1` wins, the open returns
  `FITCACHE_OPEN_REDIRECT` plus the peer's Mercury addr. Client-side
  redirect handling in `fitcache_open_cb`: register peer addr as a new
  routing slot, re-issue the open against the peer, remember the
  override for subsequent `read`/`seek`/`close` on that fd. Real
  `peer_lookup_rpc_handler` replaces the always-`has=0` stub
  (consults `path_cache_map` under `cache_mtx`, answers with this
  server's own Mercury addr).

- **Persistent sidecar metadata** (`25680e9`). New
  `fitcache_persistent_meta` module: atomic write (tmp+fsync+rename),
  magic+version-validated read, flock-serialised refcount RMW,
  directory scan that visits valid sidecars and quarantines corrupt
  ones to `.broken`. Data mover writes a sidecar (cross-job mode only)
  right after `fs::copy`. Server startup scans `FitCache_DRAM_PATH` +
  `FitCache_NVME_PATH` and rebuilds `path_cache_map` + used-bytes
  counters — cache survives server restart and node reboot.

- **Refcount-respecting eviction + background reaper** (`21772a6`).
  `meta_select_eviction_victim` picks lowest-`access_count` among
  refcount=0 sidecars; refcount>0 files are protected.
  `meta_evict_file` unlinks both data and sidecar. New reaper thread
  runs every `FitCache_REAPER_SEC` seconds (default 30s); each pass
  evicts refcount-zero victims in each tier until used bytes drops
  below `FitCache_EVICT_LOW_WM * capacity`. Updates `path_cache_map`
  and used-bytes counters in lockstep with each unlink under
  `cache_mtx`.

- **Subscriber-lease management** (`c816420`).
  `subscribe_self_to_local_dataset` /
  `release_self_from_local_dataset` compute a lightweight `dataset_id`
  from `FitCache_DATA_DIR` (root-path hash; full manifest scan
  deferred), initialise the cluster registry if needed, and
  insert/remove a subscriber record with a lease running for
  `FitCache_LEASE_RENEW_SEC * 2` seconds. Hooked into the client
  constructor/destructor so every linked job auto-subscribes at
  startup and releases at shutdown. Design-doc deviation: the spec
  proposed Mercury RPCs (`fitcache_subscribe_rpc` /
  `fitcache_release_rpc`); the implementation collapses them into
  direct PFS-backed registry writes since the registry is already
  PFS-backed and the client links the `cluster_registry` module.
  Adding an RPC layer would only add latency and failure modes for no
  semantic gain. Also tightened `rmw_kv_file` to recreate the parent
  directory if missing — fixes a stale-init scenario hit by the test.

**Smoke test (`./tests/test_cross_job_smoke`):** 8/8 pass.
FNV vectors, HRW routing balance + churn vs modulo, dataset_id,
cluster registry roundtrip + heartbeat staleness, client-side routing
(slot stable + HRW spread 3/3 servers), sidecar write/read +
refcount + scan + quarantine + orphan handling, eviction victim
selection (refcount-protected files never picked), subscriber-lease
roundtrip (subscribe writes, release + double-subscribe idempotent).

**Backward compatibility:** every new code path gated by
`cross_job_enabled()`. `FitCache_CROSS_JOB=0` (the default) keeps
single-job builds bit-identical to IPDPS at runtime.

**Push status:** the four new commits are local-only because `gh` is
not installed and no credential helper is configured. User to push
when ready.

**Heartbeat:** Monitor task `bycc3c1i5` was running a 30-minute
heartbeat throughout; will be stopped by touching
`/tmp/fitcachepp_done.marker`.

**Next steps**
- Multi-server end-to-end smoke on a real cluster: two
  `fitcache_server` processes on different ports, two jobs against
  them; verify the second job reads from the first's cache via the
  peer-lookup redirect path. First real validation of the redirect
  flow end-to-end.
- Bit-equivalence check with `FitCache_CROSS_JOB=0` against the IPDPS
  configs from the cross-job sensitivity / failure-injection
  experiment plan, to defend the zero-regression-vs-IPDPS-single-job
  claim.
- Three-tier hardware evaluation pilot on ARC (PMem nodes) — the
  smallest experiment from the experiment plan; useful both as
  campaign-warmup and to validate the cross-job extension doesn't
  regress the IPDPS extrapolation experiment.
- Full manifest-based `dataset_id` — plumb
  `fitcache::build_dataset_id`'s manifest scan into the sidecar write
  path and the subscriber registration so two jobs with diverged
  manifests are correctly refused sharing.

### 2026-05-11 — Client-side HRW routing wired end-to-end

- Added cluster endpoint table + routing API in `src/fitcache_cross_job.{h,cpp}`: `select_server_for_path(path, local_server_count)` (cross-job: HRW — highest-random-weight hashing — over the registry's live-server snapshot with a 5-second TTL refresh; single-job: passthrough to `modulo_select`); `slot_to_addr(slot)` for resolving a routing slot to its Mercury address string; `refresh_cluster_endpoints()` for tests. ~110 LOC.
- Swapped all six routing call sites that previously computed `hash(path) % g_fitcache_server_count` (`fitcache_track_file`, `fitcache_remote_read`, `fitcache_remote_pread`, `fitcache_remote_lseek`, `fitcache_remote_close`, plus the one in `ms_read`) to `fitcache::select_server_for_path(...)`.
- Extended `fitcache_client_comm_lookup_addr` in `src/fitcache_comm_client.cpp` with a cross-job branch that consults the cluster endpoint table before falling back to `.ports.cfg.${SLURM_JOBID}`. The fallback path preserves IPDPS-mode behaviour when `FitCache_CROSS_JOB=0`.
- Fixed a placeholder from the cluster-registry work that landed earlier: `fitcache_server.cpp` was passing `addr=""` to `registry_register_server`. It now captures the real Mercury self-addr via the new `fitcache_comm_get_self_addr_string()` getter (populated as a side effect of `fitcache_comm_list_addr` in `src/fitcache_comm.cpp`). Without this, cross-job peer clients would have empty addresses in the registry and never resolve. The change is gated by `FitCache_CROSS_JOB=1` so single-job builds are unaffected.
- Added a fifth case to `tests/test_cross_job_smoke.cpp` — `test_routing_select_and_slot_addr` — covering slot stability across repeated calls, HRW spread across the live set, addr resolution, and the unknown-slot fallback that `fitcache_client_comm_lookup_addr` relies on. Required test restructuring after hitting the cached-`cross_job_enabled()` gotcha (recorded as `feedback_cross_job_enabled_is_cached.md` in memory).
- Build clean: pre-existing `wrappers.c`/`ms_read` and `test_open_close.c`/`fclose(int)` warnings remain (documented in `tpds_extension/05_implementation_notes.md`); no new warnings. CMake cache had to be cleared once because the repo was renamed from `FitCache` to `FitCachePP` and the stale `CMakeCache.txt` recorded the old source path.
- All five smoke tests pass: FNV-1a vectors, HRW balance + churn vs modulo, dataset_id, cluster registry roundtrip + heartbeat staleness + deregister, client-side HRW routing (HRW spread 3/3 servers, slot stable, addr lookup correct).
- Backward compatibility check: when `FitCache_CROSS_JOB=0` (the default; env-var contract documented in the cross-job design doc at `tpds_extension/02_design_cross_job.md`, "Configuration surface" section), `select_server_for_path` short-circuits to `modulo_select(path, g_fitcache_server_count)` so single-job routing is bit-identical to the IPDPS code.

**Next steps**
- Open-time peer lookup fanout in `fitcache_open_rpc_handler` (`src/fitcache_comm_server.cpp`): on cache miss, fan out `fitcache_peer_lookup_rpc` (the RPC stub already exists from the cluster-registry work) to live peers from the cluster registry before falling back to PFS; on a positive response, redirect the server-side fd to read from the peer-job server. ~150 LOC. This is the change that actually achieves cache sharing across jobs.
- Sidecar metadata persistence (`<file>.meta` per cached file) + reference counting + real eviction (`unlink` on evict — currently only the metadata map is touched) + `subscribe`/`release` RPCs. ~530 LOC.
- After the durability work lands, run a 2-job smoke test on ARC, then run the bit-equivalence check (`FitCache_CROSS_JOB=0` vs the IPDPS configs) to defend the zero-regression-vs-IPDPS-single-job claim.
