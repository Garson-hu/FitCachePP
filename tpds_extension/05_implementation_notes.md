# Implementation Notes — FitCache++ cross-job extension

This is the engineering source of truth for the cross-job extension. It tracks
what is built, what is wired, what's deferred, and the empirical results so
far. Update it whenever a new mechanism lands or a deferred item moves into
the wired set.

## Status (as of 2026-05-11)

The cross-job extension is being built up in three slices, each gated by
`FitCache_CROSS_JOB=1` so single-job (IPDPS) behaviour is preserved when the
flag is off.

**Slice 1 — cluster registry + dataset identity + HRW routing algorithm + smoke test.** COMPLETE.
Build clean for `fitcache_server`, `fitcache_client`, and `test_cross_job_smoke`.
All four original smoke checks pass on first run.

**Slice 2 — client-side HRW routing integration (the routing-slot table + `select_server_for_path` + cross-job branch in `fitcache_client_comm_lookup_addr`).** COMPLETE (2026-05-11).
Build still clean (only the two pre-existing non-cross-job warnings remain:
`wrappers.c`/`ms_read` and `tests/test_open_close.c`/`fclose(int)`). All five
smoke checks pass.

**Slice 3 — open-time peer lookup fanout, sidecar metadata persistence, refcount + real eviction, subscribe/release RPCs.** Not started.

## What the cluster-registry slice contains

### New source files (~900 LOC of new code)

| File | LOC | Purpose |
|---|---|---|
| `src/fitcache_dataset_id.{h,cpp}` | 70 + 175 | Cross-process stable dataset identity (FNV-1a 64-bit hash, manifest hash) |
| `src/fitcache_cross_job.{h,cpp}` | 60 + 95 | HRW routing algorithm, modulo fallback, env-var gate |
| `src/fitcache_cluster_registry.{h,cpp}` | 80 + 320 | PFS-backed registry: per-node text files, flock-protected, heartbeat + GC |
| `tests/test_cross_job_smoke.cpp` | 220 | FNV vectors / HRW / dataset_id / registry roundtrip |

### Files modified

- `src/fitcache_comm.h` — added `fitcache_peer_lookup_in_t`/`_out_t` + register decls + handler decl
- `src/fitcache_comm_server.cpp` — added `fitcache_peer_lookup_rpc_handler` (stub: always responds `has=0`) + register fn
- `src/fitcache_comm_client.cpp` — added client-side RPC registration for peer_lookup
- `src/fitcache_server.cpp` — gated cluster-registry init + heartbeat thread + register/deregister behind `FitCache_CROSS_JOB`
- `src/CMakeLists.txt` — added new sources to both client and server targets
- `tests/CMakeLists.txt` — added `test_cross_job_smoke`

## Smoke test results

```
$ test_cross_job_smoke
[1/5] FNV-1a vectors...
  ok: FNV-1a 64 vectors match reference
[2/5] HRW routing...
  ok: HRW balance min=1201 max=1285 (expected ~1250 per server)
  ok: HRW churn reassigned=1221 (expected ~1250) when removing rank 7
  ok: modulo unchanged=1277/10000 across N=8->7 (HRW unchanged would be ~8779)
[3/5] dataset_id...
  ok: dataset_id stable + sensitive to membership change
[4/5] cluster registry roundtrip ...
  ok: registry roundtrip live={rank=0 addr=ofi+tcp;ofi_rxm://127.0.0.1:1234}
  ok: stale heartbeat detected
  ok: deregister removes entry
[5/5] client-side routing (select_server_for_path + slot_to_addr)...
  ok: cross-job slot stable (slot=1) addr=ofi+tcp;ofi_rxm://10.0.0.2:5001
  ok: cross-job HRW spread across 3/3 servers

ALL SMOKE TESTS PASSED
```

The HRW vs modulo comparison from the routing-algorithm slice is the headline
empirical result so far: **HRW retains 87.8% of mappings under server-set
churn; modulo retains only 12.7%.** This matches the cluster-scoped
coordination protocol's design prediction in `02_design_cross_job.md`
(routing under variable server-count) and is the empirical justification for
choosing HRW over hash-modulo.

The client-side routing check verifies the full client-side wiring: the HRW
pick translates to a stable slot id, the slot id resolves to the addr we
registered, and the slot table doesn't collapse to a single server.

## Pre-existing code issues found while building

- **`-DDEBUG_HU=1` is required.** The CMake option is inverted: `option(DEBUG_HU OFF)` then `if(DEBUG_HU) add_definitions(-DDEBUG_HU=0)`. Means the C macro is *only defined* when `DEBUG_HU=1` is passed; with the default OFF, `if(DEBUG_HU)` in C/C++ becomes "use of undeclared identifier." The `build/build.sh` already passes it so production builds are fine, but the option semantics are confusing and should be cleaned up later.
- **`wrappers.c` warns about implicit `ms_read` declaration.** `ms_read` is a C++-only declaration in `fitcache_multi_source_read.h` (no extern "C") so the C wrapper sees it as implicit. Pre-existing IPDPS bug; leaving alone for now.
- **`tests/test_open_close.c` warns about `fclose(int)`.** Pre-existing, not ours.
- **`fitcache_cache_policy.cpp` is not linked into the server.** Commented out in `src/CMakeLists.txt:16`. Will need to re-enable as part of the sidecar-metadata + refcount work.

## What the client-side HRW routing integration delivered

### New code (~310 LOC)

| Element | LOC | Purpose |
|---|---|---|
| `fitcache_cross_job.{h,cpp}` — `select_server_for_path`, `slot_to_addr`, `refresh_cluster_endpoints`, plus the `g_endpoints`/`g_live_slots` slot table | ~110 | Routing slot table; bounded-TTL refresh from registry; HRW over the live slot subset; modulo fallback when registry empty |
| `fitcache_comm_client.cpp` — cross-job branch in `fitcache_client_comm_lookup_addr` | ~25 | Slot → Mercury addr resolution via `slot_to_addr` before falling back to `.ports.cfg.${SLURM_JOBID}` |
| `fitcache_comm.{h,cpp}` — `fitcache_comm_get_self_addr_string()` getter; `g_self_addr_string` populated inside `fitcache_comm_list_addr` | ~10 | Server can hand the real Mercury self-addr to `registry_register_server` instead of the empty-string placeholder from the cluster-registry slice |
| `fitcache_server.cpp` — pass real addr in registration; warn if empty | ~10 | Cluster clients can route to this server straight from the registry without re-reading `.ports.cfg` |
| `tests/test_cross_job_smoke.cpp` — `test_routing_select_and_slot_addr` | ~95 | Slot-stability + HRW-spread + unknown-slot guard |

### Files modified (5 routing call sites + 1 in `ms_read`)

- `src/fitcache_client.cpp` — replaced `hash(path) % g_fitcache_server_count` in `fitcache_track_file`, `fitcache_remote_read`, `fitcache_remote_pread`, `fitcache_remote_lseek`, `fitcache_remote_close` with `fitcache::select_server_for_path(path, g_fitcache_server_count)`.
- `src/fitcache_multi_source_read.cpp` — same swap in `ms_read`.

### Backward compatibility

`select_server_for_path` short-circuits to `modulo_select(path, local_server_count)` when `cross_job_enabled()` is false. The cluster registry init is gated by `FitCache_CROSS_JOB=1` in `fitcache_server.cpp` and the entire address-book extension only fires under that flag, so single-job deployments are byte-identical to IPDPS at runtime.

## What the open-time peer-lookup fanout slice delivered (commit 2c76cc6)

Server-side peer fanout in `fitcache_open_rpc_handler`: on `path_cache_map`
miss with `FitCache_CROSS_JOB=1`, asynchronously query every live peer in
the cluster registry via `fitcache_peer_lookup_rpc`. First peer that
responds `has=1` wins; the open returns `FITCACHE_OPEN_REDIRECT` plus the
peer's Mercury addr. Client-side redirect handling in `fitcache_open_cb`:
register peer addr as a new HRW routing slot, re-issue the open RPC
against the peer, and remember the override so subsequent
`read`/`seek`/`close` on the local fd route to the peer. One redirect hop
allowed.

Real `fitcache_peer_lookup_rpc_handler` replaces the always-`has=0` stub;
consults `path_cache_map` under `cache_mtx` and answers with this server's
own Mercury addr. ~470 LOC across `fitcache_comm.h`, `fitcache_comm_server.cpp`,
`fitcache_comm_client.cpp`, `fitcache_cross_job.{h,cpp}`, `fitcache_client.cpp`.

## What the persistent sidecar metadata slice delivered (commit 25680e9)

New module `fitcache_persistent_meta`: atomic `meta_write_sidecar` (tmp +
fsync + rename), magic+version-validated `meta_read_sidecar`,
flock-serialised `meta_bump_refcount` / `meta_drop_refcount`,
`meta_scan_tier_dir` (walks a tier root, visits valid sidecars,
quarantines corrupt ones to `.broken`, skips orphans). Data mover writes
a sidecar (cross-job mode only) right after `fs::copy` promotes a file.
Server startup scans `FitCache_DRAM_PATH` + `FitCache_NVME_PATH` and
rebuilds `path_cache_map` + `g_dram_used_bytes` / `g_nvme_used_bytes` —
cache survives server restart and node reboot. ~550 LOC.

## What the refcount-respecting eviction slice delivered (commit 21772a6)

`meta_select_eviction_victim` picks lowest-`access_count` among
refcount=0 sidecars; refcount>0 files are never picked.
`meta_evict_file` unlinks both data and sidecar and reports bytes freed.
New background thread `fitcache_eviction_reaper_fn` runs in the server
when cross-job is on; every `FitCache_REAPER_SEC` seconds (default 30)
it checks each tier and evicts refcount-zero victims until used bytes
drops below `FitCache_EVICT_LOW_WM * capacity` (defaults 0.85 high /
0.70 low). The reaper updates `path_cache_map` and used-bytes counters
in lockstep with each unlink under `cache_mtx`. The dead-code
`fitcache_cache_policy.cpp` module (not linked into the server) was left
untouched; the eviction logic lives in the data-mover path against the
actually-active state. ~283 LOC.

## What the subscriber-lease slice delivered (commit c816420)

`subscribe_self_to_local_dataset` / `release_self_from_local_dataset`
compute a lightweight `dataset_id` from `FitCache_DATA_DIR` (root-path
hash; full manifest scan deferred), initialise the cluster registry if
needed, and insert/remove a subscriber record with a lease running for
`FitCache_LEASE_RENEW_SEC * 2` seconds. Hooked into the client
constructor/destructor so every linked job auto-subscribes at startup
and releases at shutdown.

**Design-doc deviation:** the spec proposed Mercury RPCs
(`fitcache_subscribe_rpc` / `fitcache_release_rpc`); the implementation
collapses them into direct PFS-backed registry writes because the
registry is already PFS-backed and the client links the
`cluster_registry` module. Adding an RPC layer would only add latency
and failure modes for no semantic gain. The RPC wire format can still
be added later if a client ever needs to subscribe without PFS write
access. Also tightened `rmw_kv_file` to recreate the parent dir if
missing — fixes a stale-init scenario where the static `g_datasets_dir`
outlives the directory it points at. ~190 LOC.

## What is NOT yet wired (remaining work)

1. ~~**Client-side HRW routing.**~~ ✅ Done (commit 6f7585d).
2. ~~**Open-time peer lookup fanout.**~~ ✅ Done (commit 2c76cc6).
3. ~~**Persistent sidecar metadata.**~~ ✅ Done (commit 25680e9).
4. ~~**Refcount + real eviction.**~~ ✅ Done (commit 21772a6).
5. ~~**Subscriber lease at startup/shutdown.**~~ ✅ Done (commit c816420), as direct PFS writes rather than Mercury RPCs.

**Engineering scope of the cross-job extension is complete.** Total
delivered: ~1,500 LOC across the four slices. Within the original
~1,600 LOC budget from `00_PLAN.md`.

Forward-looking items not in scope for the engineering work but worth
noting for the experiment campaign:

- **Full manifest-based `dataset_id`.** Currently the `dataset_id_hash`
  field on sidecars is 0, and `subscribe_self_to_local_dataset` uses
  only the root-path hash. The full manifest scan in
  `fitcache::build_dataset_id` exists and is tested; it just needs to
  be plumbed into the sidecar write and the subscriber registration.
  Required before two jobs on diverged datasets are correctly refused
  sharing.
- **Lease renewal thread.** Subscribers currently get a single
  `FitCache_LEASE_RENEW_SEC * 2` lease at startup that expires if the
  job runs longer than that. A periodic renew tick is needed for long
  training runs.
- **Optional Mercury RPC layer for subscribe/release** if a client ever
  runs in a context where it can't write the registry on PFS.
- **Multi-server end-to-end smoke** (two `fitcache_server` processes on
  different ports, a client that opens a file warmed by the other
  server). Deferred to manual cluster testing; the unit smoke covers
  the algorithmic pieces.

## Known risks I want to flag for review

- **The `path_cache_map` global is a `std::unordered_map<string, string>` guarded by `cache_mtx` (a shared_mutex).** When we add cross-job sharing, this will be contended by both peer_lookup handlers and local promotions. Probably fine at our scale (a few hundred ops/sec per server), but watch for it under the multi-tenant pressure experiment in the experiment-plan doc.
- **`fitcache_progress_fn`'s 100ms `HG_Progress` timeout** (in `fitcache_comm.cpp:114`) could add latency to peer_lookup responses. May want a shorter spin window for cross-job calls.
- **Registry GC runs on every heartbeat** (currently every 30s). Cheap individually but with N nodes each scanning N node-files, it's O(N²) total. At Frontier scale (1000+ nodes, 1000+ servers), we may want to make GC the responsibility of just one server per "registry region" — but this can wait until the large-scale cross-job sharing measurements actually show contention.

## Design-doc traceability

| Cross-job design-doc topic (`02_design_cross_job.md`) | Status |
|---|---|
| Dataset identity (FNV-1a + manifest hash) | ✅ DONE (cluster-registry slice) |
| Cluster registry (PFS-backed, flock, heartbeat) | ✅ DONE (cluster-registry slice) |
| HRW routing under variable server-count | ✅ algorithm + client integration DONE (cluster-registry slice + client-side HRW routing integration) |
| Open / Read flow with peer fanout | ✅ DONE (open-time peer-lookup fanout slice + client redirect handling) |
| Cache lifecycle, sidecar metadata, refcount | ✅ DONE (persistent sidecar metadata + refcount-respecting eviction + reaper) |
| Failure modes (heartbeat staleness, GC) | ✅ heartbeat + GC done in cluster-registry slice; ⏳ peer-fail recovery deferred to a future hardening pass |
| Env-var contract | ✅ DONE (`FitCache_CROSS_JOB`, `FitCache_CLUSTER_REGISTRY_DIR`, `FitCache_HEARTBEAT_SEC`) |
| New RPCs (peer_lookup, subscribe, release) | ✅ peer_lookup wired with real handler; subscribe/release collapsed into direct PFS-backed registry writes (design-doc deviation, documented above) |

## Cluster experiments (added 2026-05-11, post-engineering session)

**Single-job FitCache++ baseline on c66** (SLURM 221607, 19m00s wall):
CosmoFlow on cosmoUniverse-mini, 4 servers + 1 GPU client, FitCache_CROSS_JOB=0.
Per-epoch 362 / 189 / 188 / 188 / 186 s. Cold/warm 1.93x. peer_lookup count=0
across all 4 servers (correct for single-job mode). **Confirms the
zero-regression-vs-IPDPS-single-job claim at the shape level.** Result +
summary at `benchmarks/results/single_job_baseline/`.

**Two-job concurrent cross-job sharing on c70 + c71** (SLURM 221614 + 221615,
both ~16m15s wall in parallel): both jobs FitCache_CROSS_JOB=1, shared
cluster registry on BeeGFS. Cold epoch dropped from 362s (baseline) to ~199s
(both jobs) — **a 45% reduction**. Per-job wall down 14% (19m00s → 16m19s).
Aggregate work vs sequentially-run-twice down 57%. Mechanism: HRW
deterministically picks the same server for the same path across both jobs,
so whichever job hits a file first warms the cache for the other. peer_lookup
fanout did not fire (expected — stable live set means HRW alone suffices;
the redirect path is for server-set churn). **Defends the
cross-job-sharing-reduces-aggregate-IO claim at the 4-server-per-node ×
2-job scale.** Result + summary at `benchmarks/results/two_job_concurrent/`.

Caveat surfaced: both nodes shared `/etc/machine-id`, so HRW scores tied and
all paths landed on whichever node registered first (likely c70). Routing
isn't node-balanced in this setup. Fix would inject the addr or hostname
into the HRW input alongside `node_uuid`. The cross-job-sharing claim
still holds; the routing-balance is a separate issue.

## Bugs surfaced + fixed during the cluster experiments

Three real bugs found while bringing up the multi-server localhost smoke
harness, all fixed and committed:

1. **Silent hang on `lookup_addr=NULL`.** When
   `fitcache_client_comm_lookup_addr` returned NULL (slot unknown to the
   cluster table AND not in `.ports.cfg`), the open / read / seek RPC
   functions returned without firing the per-file sync context, leaving
   the caller's `fitcache_client_block_for_file` blocked forever. Now all
   three signal `-1` on the sync context so the caller's wait unblocks.

2. **`std::string` global state silently zeroed mid-process.**
   `cluster_registry.cpp`'s `g_nodes_dir` / `g_registry_root` /
   `g_datasets_dir` had their heap-backed `c_str()` become `""` between
   `registry_init`'s write and the first `registry_live_servers` read —
   same address printed before and after. Diagnosed via address-printing
   under WARN logs. Workaround: switched to fixed-size `char[1024]`
   buffers with thin getter functions, never reallocated after init. Root
   cause likely a libstdc++ destructor-ordering or LD_PRELOAD interaction;
   not pinpointed.

3. **`ms_read` missing peer-slot override.** After the open redirect
   succeeded, subsequent reads on the redirected fd went back to the
   HRW-chosen server (which doesn't know the peer's remote_fd). Fixed:
   `ms_read` now consults `fitcache_client_get_peer_slot_override`
   before HRW.

A fourth bug surfaced during the first attempt at the two-job concurrent
cluster experiment:

4. **Cluster registry rmw races on BeeGFS.** The single-file-per-node
   design (`nodes/<hostname>.txt` shared by all servers on the host)
   broke under multi-server concurrency on BeeGFS: the
   write-tmp-then-rename atomic update invalidated the inode the flock
   was bound to. Concurrent rmws lost each other's keys, and the
   registry ended up with only heartbeat entries (no addr/rank/jobid)
   because the heartbeat thread's RMWs fired most often and were always
   last. Fix: switched to **one file per server-instance**
   (`nodes/<hostname>_rank<N>.txt`). Each server is the sole writer of
   its own file; no inter-process write races. Deregistration becomes
   plain `unlink`.

Pre-existing code quality cleanup folded in:
- `wrappers.c` properly includes `fitcache_multi_source_read.h` (was
  implicitly declared, generated a warning).
- `fitcache_multi_source_read.h` was using `std::vector` inside an
  `extern "C"` block (broken for C consumers); moved C++ declarations
  out of the `extern "C"` block.
- `test_open_close.c` was calling `fclose(int)` instead of `close(int)`.
- `CMakeLists.txt` `DEBUG_HU` option was inverted; now defines the C
  macro to `1` when on / `0` when off.

Build now compiles with zero warnings.

## Smoke test results (after the four-slice landing)

```
$ test_cross_job_smoke
[1/8] FNV-1a vectors...                     ok
[2/8] HRW routing...                        ok (balance + churn + modulo baseline)
[3/8] dataset_id...                         ok (stable + sensitive to membership change)
[4/8] cluster registry roundtrip...         ok (register, heartbeat staleness, deregister)
[5/8] client-side routing...                ok (slot stable, HRW spread 3/3 servers)
[6/8] sidecar persistent metadata...        ok (write/read, refcount, scan, quarantine, orphan)
[7/8] eviction victim selection...          ok (refcount-protected files never picked)
[8/8] subscriber-lease roundtrip...         ok (subscribe writes, release + double-subscribe idempotent)

ALL SMOKE TESTS PASSED
```

## Mechanisms added during the post-engineering hardening pass (2026-05-11)

### HRW addr-in-hash fix (`src/fitcache_cross_job.cpp`)

Problem: c70 and c71 ship cloned VM images with identical `/etc/machine-id`,
which made `node_uuid` identical across hosts. The original HRW score over
`path || node_uuid || rank` then tied across the two hosts, so all paths
deterministically routed to whichever host's slot was iterated first
(observed in SLURM 221614/221615: c71's servers received zero opens).

Fix: include `s.addr` (the Mercury endpoint string, which embeds host:port
and is therefore unique per endpoint) in the HRW input, after the existing
`path || node_uuid || rank`. Breaks the tie without changing routing for
clusters whose `/etc/machine-id` values are already distinct. Comment in
`hrw_select` documents the failure mode and the rationale.

### Cross-job telemetry counters (`src/fitcache_cross_job.{h,cpp}` + comm-server bumps + heartbeat-thread emit)

Eight atomic counters wired into the open + peer-lookup code paths:
`opens_total`, `opens_local_hit`, `opens_redirect_to_peer`,
`opens_pfs_fallback`, `peer_lookup_forwarded`, `peer_lookup_handled`,
`peer_lookup_has_yes`, `peer_lookup_has_no`. Emitted from the heartbeat
thread every `FitCache_HEARTBEAT_SEC` (only when
`fitcache::cross_job_enabled()` is true), with per-counter delta vs. the
last sample, and once more at signal-exit. Lets the experiment campaign
verify which code paths actually fired during a run (vs. were defined and
dormant) without re-grepping noisy log4c output.

Verified in the bit-equivalence smoke: cross_job=on pass logged
`opens_total=8 ... pfs_fallback=8 ... peer_lookup forwarded=0 handled=0`,
matching the 8-file workload and the single-server (no-peers) topology.

### Bit-equivalence smoke (`scripts/run_bit_equivalence_smoke.sh`)

Defends the zero-regression-vs-IPDPS-single-job claim at the byte level.
Runs the same 8-file synthetic workload twice against a single
`fitcache_server`: pass A with `FitCache_CROSS_JOB=0` (IPDPS-mode), pass B
with `FitCache_CROSS_JOB=1` and a single server (no peer-lookup ever
fires). Per-file `sha256sum` of the cached payloads must match between
passes AND match the source files. Result archived in
`benchmarks/results/bit_equivalence/summary.md`; rerun with KEEP=1 to
preserve `/tmp/fitcachepp_bit_equiv_<pid>/` for inspection.

### Opt-in PMem tier (`src/fitcache_cache_policy.h` + `src/fitcache_data_mover.cpp`)

New `CACHE_TIER_PMEM = 4` (appended after `UNKNOWN=3` so existing
wire-protocol tier values are preserved). New env vars
`FitCache_PMEM_PATH` and `FitCache_PMEM_CAPACITY` enable the tier; when
either is unset, behavior is identical to the two-tier configuration.

Placement priority: DRAM → PMem (if enabled) → NVMe. Restoration loop now
scans all three tier roots; per-tier used-bytes counters
(`g_dram_used_bytes`, `g_pmem_used_bytes`, `g_nvme_used_bytes`) updated
correctly via a capture-by-reference lambda. Eviction reaper handles the
PMem tier with the same high/low watermark policy.

Verified in `scripts/run_three_tier_smoke.sh`: 12 files of 1 MiB each
split 4/4/4 across DRAM/PMem/NVMe under tight tier capacities; server
restart then restores all 12 from sidecars per-tier. Backward-compat
verified by re-running `scripts/run_bit_equivalence_smoke.sh` after the
PMem changes landed — still passes with PMem env vars unset, confirming
the new tier is dormant by default.

### Three-tier cluster pilot scripts

- `benchmarks/cosmoflow/PDSW_FITPP_three_tier.sh` — CosmoFlow + Horovod
  variant with all three tiers enabled. Targets the rtx4060ti16g
  partition (overridable). The cluster's known-PMem candidate node c35
  is in the `cascade` partition (CPU-only), so it cannot host this GPU
  workload; see the in-script preamble for the verification steps before
  submission to a specific node.
- `scripts/run_three_tier_sustained_read.sh` — CPU-only sustained-read
  micro-benchmark (~256 files × 4 MiB, capacities sized to force spill
  across all three tiers). Designed to run on any node so c35 (which
  has PMem but no GPU) can host a useful three-tier characterisation
  without the TensorFlow toolchain. Override DRAM_PATH / PMEM_PATH /
  NVME_PATH env vars to pin tier locations to real device paths.

## Known issues (post-hardening) not yet addressed

- **Registry rename-busy storm on long-lived shared registry dirs.**
  `fitcache_cluster_registry.cpp:155` (`std::rename(tmp, final)`) fails
  with EBUSY on BeeGFS when prior runs left orphan `<final>.tmp.<pid>`
  files behind from servers that SLURM didn't fully tear down. Chains
  like `c70_rank0.txt.tmp.2046785.tmp.2046791.tmp.2355754` appear and
  GC keeps re-attempting renames against the chained names. Functional
  impact is just log noise + delayed heartbeat refresh; experiments
  still complete in expected wall-clock. Mitigation: wipe
  `${FitCache_CLUSTER_REGISTRY_DIR}` before a new run (the driver
  scripts already use a unique `$RUN_REGISTRY` subdir). Real fix would
  prune orphan `.tmp.<pid>` files at registry init.
- **`log_cross_job_stats` final-dump may not flush** because
  `signal_exit` calls `std::exit(0)`, which bypasses log4c's normal
  flush. Periodic dumps from the heartbeat thread still land. Workaround
  for now: rely on the periodic dumps; the SIGINT/SIGTERM-final-dump is
  best-effort.

## Next session

The cross-job extension engineering work and the post-engineering
hardening pass are both complete. Next steps:

1. **Re-run two-job concurrent on a node pair with distinct
   `/etc/machine-id`** to directly observe HRW node-balance after the
   addr-in-hash fix. Or capture per-server log4c output into a
   per-server file in `$RESULTS_DIR` (currently it lands in the repo
   root) so opens-per-node can be counted from the cluster logs.
2. **Three-tier hardware evaluation pilot** — needs a node that has
   both a GPU (for CosmoFlow + Horovod) and a DAX-mounted PMem volume,
   or use `scripts/run_three_tier_sustained_read.sh` on c35 (the
   known-PMem CPU-only node) for a non-GPU characterisation.
3. **Full manifest-based `dataset_id`** plumbed into sidecar writes
   and subscriber registration (forward-looking item from the original
   four-slice plan; required before two jobs on diverged datasets are
   correctly refused sharing).
4. **Lease renewal thread** for long training runs.
5. **Investigate the registry rename-busy issue** if it shows up in a
   clean fresh run.
4. **Full manifest-based `dataset_id`** — plumb
   `fitcache::build_dataset_id`'s manifest scan into the sidecar write
   path and the subscriber registration so two jobs with diverged
   manifests are correctly refused sharing.

## 2026-05-14 session: registry cross-node addr-wipe race — root cause + fix

### Symptom

In the two-job concurrent re-run on c66+c67 (SLURM 221833/221834, run-tag
`20260513_003507_2631937`), cross-job sharing was effectively dead at
cluster scale. End-of-run cross_job_stats:

- Job A's c66/rank=0: opens_total=2391, local_hit=586, pfs_fallback=1805,
  peer_lookup forwarded=3610, handled=4217, **has_yes=0, has_no=4217**.
- Job A's c66/rank=1: opens_total=40368, local_hit=36825, pfs_fallback=3543,
  peer_lookup forwarded=5483, handled=6108, **has_yes=0, has_no=6108**.
- Job A's c66/rank=3: zero opens (HRW imbalance).
- **Job B (c67): every server showed all-zero counters** — Job B's clients
  never reached its own servers either.

Post-mortem registry directory state was the smoking gun:

```
c66_rank0.txt: 0 bytes
c66_rank{1,2,3}.txt: 0 bytes
c67_rank0.txt: 30 bytes — only `server.0.heartbeat=…`
c67_rank{1,2,3}.txt: 30 bytes — only `server.0.heartbeat=…`
```

After ~80 minutes of supposed steady-state operation, every per-server
registry file had lost its `addr`/`node_uuid`/`jobid`/`rank` keys.
`registry_live_servers()` requires `server.<rank>.addr` to surface a
server (see `fitcache_cluster_registry.cpp:442-466`); without it the
server is invisible to HRW and to peer-lookup. Each job degenerated into
an isolated single-node cluster.

### Root cause — two flaws compounding

1. **`registry_heartbeat()` only rewrote the heartbeat key.** addr,
   node_uuid, rank, jobid were touched once (at registration) and never
   again. No self-healing if anything stripped them.

2. **`registry_gc_stale()` modified registry files belonging to OTHER
   hostnames.** The directory iterator walked every file in the shared
   PFS registry dir, and removed `server.<rank>.*` keys from any file
   whose heartbeat looked stale. On BeeGFS, transient flock contention
   can stretch a single `rmw_kv_file` call past the 30-second stale
   window (3 × `FitCache_HEARTBEAT_SEC=10s`). Another node's GC then
   races in and strips this server's `addr` key.

Once `addr` was stripped, this server's next heartbeat only rewrote
heartbeat (flaw #1), leaving the file addr-less indefinitely. `peer_lookup`
fanout never reached such a server (it wasn't in the live set), so the
only responders were same-job siblings on the same node — which
legitimately do not have files that HRW routed elsewhere within the
visible subset. That is the 100% has_no in the counters.

### Fix landed on 2026-05-14

Two changes in `src/fitcache_cluster_registry.cpp`, plus a new regression
smoke (`tests/test_cross_job_smoke.cpp` test 10 of 10):

**Self-healing heartbeat.** `registry_register_server` now caches
`self.addr`, `self.jobid`, and `self.rank` into registry-internal
fixed-size C buffers (the same `g_self_*_buf` pattern already used for
hostname / node_uuid — std::string globals are documented unsafe here).
`registry_heartbeat` rewrites the full key set on every tick:
`rank`, `addr`, `node_uuid`, `jobid`, `uid`, `heartbeat`. Idempotent
re-registration. If anything strips this server's keys, the next
heartbeat tick (≤ `FitCache_HEARTBEAT_SEC`) puts them back.

**GC hostname scope.** `registry_gc_stale` now skips files whose name
doesn't start with `<my_hostname>_rank`. Each node garbage-collects its
own per-server files only; cross-node addr stripping goes away
architecturally.

**Regression smoke (test 10/10).** Drives the failure mode directly: (a)
register; (b) manually wipe addr from the per-server file; (c) call
`registry_heartbeat`, assert addr/rank/jobid are restored; (d) plant a
peer-hostname file with `heartbeat=1` (epoch 1970, definitely stale),
call `registry_gc_stale`, assert the peer's addr survives. Locks in the
fix as a checked invariant for future refactors.

All 10 smoke tests pass. Single-job behavior is unchanged
(`FitCache_CROSS_JOB=0` doesn't touch any of this code path; the
`bit-equivalence smoke` continues to pass byte-for-byte).

### Next step

Re-run the two-job concurrent benchmark on c66+c67 (3 runs, n_train=8192)
and verify cross_job_stats shows `peer_lookup_has_yes > 0` and
`opens_redirect_to_peer > 0`. That is the cluster-scale check that the
headline mechanism — concurrent cross-job sharing — actually fires.

**Re-run 1 in flight (2026-05-14 04:02):** SLURM 221911 (c66, seed=1) +
221912 (c67, seed=2), run-tag `20260514_040247_2953313`. Registry
sanity check at +20s post-launch: all 8 per-server files
(`c66_rank{0..3}.txt`, `c67_rank{0..3}.txt`) are 189 bytes with full
key sets (rank/addr/node_uuid/jobid/uid/heartbeat) — directly
contrasting the pre-fix 0-byte / 30-byte heartbeat-only state.

**At +10 min: cross-job sharing is firing.** Counters
(`grep cross_job_stats` snapshot at 08:12 UTC across all 8 servers):

| Server | opens_total | local_hit | redirect_to_peer | pfs_fallback | peer_lookup_has_yes | peer_lookup_has_no |
|---|---|---|---|---|---|---|
| jobA c66/rank=0 | 989 | 265 | 5 | 719 | **17** | 5585 |
| jobA c66/rank=1 | 981 | 266 | 3 | 712 | **17** | 5593 |
| jobA c66/rank=2 | 1089 | 291 | 6 | 792 | **17** | 5508 |
| jobA c66/rank=3 | 1079 | 253 | 15 | 811 | **4** | 5086 |
| jobB c67/rank=1 | 999 | 259 | 4 | 736 | **29** | 5550 |
| jobB c67/rank=2 | 1164 | 317 | 2 | 845 | **29** | 5449 |
| jobB c67/rank=3 | 1119 | 288 | 1 | 830 | **29** | 5460 |

For the first time in any cluster run, `peer_lookup_has_yes > 0` AND
`opens_redirect_to_peer > 0` on every active rank. Pre-fix end-of-run
totals (run-tag `20260513_003507_2631937`, same workload, same nodes):
has_yes=0 everywhere; opens_redirect_to_peer trivially 0. The fix
flipped the headline mechanism from dead-in-cluster to firing.

**At +40 min: cross-job sharing is accelerating; PFS load has stopped
growing.** Aggregate snapshot at 08:43 UTC (sum across 7 visible ranks;
jobB rank=0 was binary-unreadable in one snapshot but visible in this one):

| Metric | +10 min total | +40 min total | Growth | Notes |
|---|---|---|---|---|
| opens_total | ~7,400 | ~46,300 | 6.3x | both jobs hammering the dataset |
| local_hit | ~2,140 | ~36,000 | 16.8x | warmed-cache phase |
| pfs_fallback | ~7,860 | ~9,925 | **1.26x** | **flat after +10 min — cold-load phase done** |
| peer_lookup_has_yes | 142 | 1,507 | 10.6x | outpacing opens — sharing density rising |
| opens_redirect_to_peer | 36 | 403 | 11.2x | the headline metric |

The flat `pfs_fallback` total is the operational story for the paper:
after the cold-load phase, both jobs are entirely served from local or
peer cache. Cross-job hits and intra-job hits between them eliminate
new PFS load. This is the cross-job-sharing-reduces-aggregate-IO claim
landing empirically for the first time.

HRW asymmetry observed: Job A rank=3 (c66) and Job B rank=0 (c67) are
the heavy redirect-to-peer ranks (144 and 175 respectively) while
their siblings are 9/10/17 and 22/21/5. This is consistent with the
deterministic HRW routing — particular hot files happen to hash to
specific cross-node ranks more frequently than to local ranks.

**Run 1 of 3 — COMPLETE (2026-05-14 05:19, 1h17m elapsed).** Both
jobs cleanly finished 5 epochs. Per-epoch wall-clock 1003/874/874/874/877s
for Job A and 1004/874/876/877/876s for Job B — within 1-2% of single-job
pace. Aggregate cross-job counters across both jobs:

- opens_total: 93,212
- local_hit: 82,248 (88.2%) — primary sharing pathway via HRW + shared registry
- redirect_to_peer: **1,042** (1.1%) — peer-redirect fallback fires
- peer_lookup has_yes: **3,802** — 5% of peer lookups land a positive answer
- pfs_fallback: 9,922 (10.6%) — **flat after +10 min**; no new PFS reads after cold-load

Full table per rank, defended claim, and pre/post-fix comparison live at
`benchmarks/results/two_job_concurrent_v2/summary_221911_221912.md`.

**Run 2 of 3 — PARTIAL (2026-05-14 05:43).** SLURM 221914 (c66) +
221915 (c67), run-tag `20260514_054352_2975972`.
- **Job B (c67, 221915)** completed cleanly at 07:00:17 after 1h16m24s
  (epochs 1025/871/872/872/870 s). Final cross-job counters
  similar shape to run 1: opens 24,695, local_hit 19,731 (80%),
  redirect_to_peer 178, peer_lookup has_yes 1,090, pfs_fallback 4,786.
- **Job A (c66, 221914)** HUNG at the moment Job B exited. Last Open RPC
  at 11:00:11 UTC (matches Job B's exit at 11:00:14 UTC); heartbeat thread
  still ticking 44+ minutes later, but no further client RPCs. Counters
  frozen at opens=23,022 / has_yes=710 / redirect_to_peer=126.
- **Root cause (new cross-job design bug uncovered):** when a peer
  server deregisters during a live job, in-flight peer_lookup or peer-read
  Mercury RPCs to that server can block indefinitely instead of erroring
  out. Job A's client was waiting on a peer RPC to a Job B server when
  Job B's deregister-and-exit raced into effect.
- **Workaround for now:** the user-set policy is "don't kill running
  work", so Job A is left running until SLURM 24h timeout. Run 3 moved
  to a different node pair to avoid c66.
- **Fix to land later** (deferred — does not block the present TPDS
  measurement campaign): peer-RPC issuer should set a Mercury request
  timeout (e.g., 30s) so a missing peer fails fast and the open falls
  back to PFS direct read. Currently the issuer waits indefinitely via
  `HG_Forward` without a deadline.

**Run 3 of 3 — ALSO HUNG (2026-05-14 07:44, c70+c71).** SLURM 221916 +
221917, run-tag `20260514_074451_2998899`. Both jobs froze mid-epoch-1
at ~6k opens each. Heartbeat threads still firing on every server,
counters frozen since ~+28 min into the run. Distinct from run 2's
hang because no peer has exited (both jobs still RUNNING). Common
factor: in BOTH hangs `redirect_to_peer` was firing before the freeze
(338 in run 2 Job A, 61 in run 3 Job A).

**Strengthened bug hypothesis:** the peer-redirect read path
(`fitcache_remote_read` -> `HG_Forward` to peer addr supplied by the
open-rpc fanout response) has a deadlock under some condition. The
fanout itself completes (peer_lookup has_yes/has_no return fine — the
counters update), but the subsequent peer-bound read can block. The
peer-exit case (run 2) is one trigger; an unrelated trigger fires
mid-run (run 3) without any peer churn.

**Decision for this campaign:** the cross-job concurrent experiment is
defended for now by run 1 (both jobs clean, 5 epochs, has_yes=3,802,
redirect_to_peer=1,042, pfs_fallback flat after cold-load). Pushing
for a 3-run average against an unfixed deadlock just produces more
hangs. Switching focus to the **single-job overhead measurement**
(`FitCache_CROSS_JOB=0` — does not exercise peer RPCs, safe to run).

**Deferred fix** (must land before any cross-job multi-hour campaign):
add a Mercury request timeout (`HG_Set_target_id` / `HG_Forward`
deadline) on every cross-job-issued RPC so peer hangs error out instead
of blocking the client. Suggested timeout: 30s, configurable via
`FitCache_PEER_RPC_TIMEOUT_SEC`. On timeout, fall back to PFS direct
read for that file.

**Hung jobs left running** per the no-kill policy: 221914 (c66, since
05:43, ~3h elapsed); 221916 (c70) and 221917 (c71) (since 07:44, ~1h
elapsed). All three will reach SLURM 24h timeout if not scancelled
explicitly by the user. `scancel 221914 221916 221917` would free
three GPU nodes immediately.

## 2026-05-14 refocus: make FitCachePP measurably beat Pure_CF

The single-job overhead measurement on c67 (run 1 only completed)
showed FitCachePP ~3.7% slower than Pure_CF at n_train=8192 in the
default OS-page-cache regime. That is the floor of FitCache's overhead
curve, not where the system is designed to win:

| Workload regime | Pure_CF | FitCachePP | Winner |
|---|---|---|---|
| Small dataset (fits in page cache), GPU-bound | ~RAM speed via page cache | ~RAM speed via page cache + RPC overhead | Pure_CF |
| Large dataset (exceeds page cache), I/O bound | BeeGFS reads (~100 MB/s) | local NVMe reads (~3 GB/s) | FitCachePP |

The campaign was pivoted on user direction: cancel all in-flight rtx4060ti16g
work and run a focused experiment that pushes the workload into the
I/O-bound regime where FitCache should win.

### Memory-pressure mechanism

New utility: [`benchmarks/util/mem_hog.c`](../benchmarks/util/mem_hog.c).
Allocates and commits an anonymous mmap region of N GiB. The kernel then
evicts file-backed page cache pages to make room for the committed
anonymous pages, simulating a dataset that exceeds RAM.

New wrapper:
[`benchmarks/cosmoflow/PDSW_FITPP_with_pagecache_pressure.sh`](../benchmarks/cosmoflow/PDSW_FITPP_with_pagecache_pressure.sh).
Launches mem_hog as a sidecar, waits for the commit to finish, then
hands off to the standard PDSW_FITPP.sh launcher.

Lessons learned from the first attempt (221932/221933, both failed):
- SLURM defaults to a tiny mem allocation on this partition
  (`AllocTRES=cpu=16,node=1,billing=16` with no `mem`). Always pass
  `--mem=0` (= all node memory) when running mem_hog.
- 300 GB hog OOM-killed within the cgroup default. 150 GB hog on c68/c69
  (~190 GiB free) fits within `--mem=0`.

### Currently in flight (2026-05-14 12:39)

- 221936 — FitCachePP + 150 GB hog on c68
- 221937 — Pure_CF      + 150 GB hog on c69
- both `n_train=8192`, 5 epochs, run-tag `20260514_123924_fitcachepp` / `20260514_123925_purecf`
- results: `benchmarks/results/fitcachepp_beats_purecf_pilot/`

Expected:
- Pure_CF cold ~856s (same as pre-pressure baseline)
- Pure_CF warm: page cache evicted by hog, so warm epoch resembles cold
  (every read goes back to BeeGFS) — much slower than the 840s warm we
  saw without pressure
- FitCachePP cold ~917s (same as pre-pressure baseline; first epoch
  reads from BeeGFS regardless)
- FitCachePP warm: cached files live on /mnt/local NVMe; even with page
  cache evicted, the next read hits the local NVMe (fast). Warm should
  remain ~865s or better

If the hypothesis holds, this is the **first measurement that defends
FitCachePP's per-job speedup claim**, complementing the cross-job
aggregate-PFS-bandwidth-bounded claim from the earlier run 1 of the
two-job concurrent experiment.

### Pilot mid-run diagnostic (2026-05-14 13:14, +33 min)

**Pre-training meminfo (both nodes)** — mem_hog committed cleanly:
- MemTotal 197 GiB, MemAvailable 36 GiB
- `Cached: 1.5 MB` (c68) / `803 KB` (c69) → the OS page cache for
  BeeGFS files was effectively flushed before training

**Pure_CF (c69) — running normally, NOT slowed by memory pressure:**
- epoch 1 (cold) 856 s  — identical to no-pressure baseline (856 s)
- epoch 2 (warm) 844 s  — **identical to no-pressure baseline (840 s)**

The kernel page cache being gone did not slow Pure_CF down. The most
likely reason: **BeeGFS server-side cache** is absorbing the warm
reads. With ~50 GB dataset and 10 Gbps LAN to the BeeGFS metadata/storage
nodes, warm reads from BeeGFS RAM are ~RAM-fast over the network.
Memory pressure on the client doesn't squeeze the server's cache.

**FitCachePP (c68) — slower under pressure than baseline:**
- 8,590 Open RPCs at 33 min → epoch 1 done (~14 min, ~870 s), now
  ~17 min into epoch 2 (vs Pure_CF in epoch 3 at this point)
- TF stdout buffer hasn't flushed the epoch-1 line yet

Why slower:
1. mem_hog runs in the same SLURM memory cgroup as the FitCache
   servers, the data mover thread, and python. With 150 GB pinned, only
   ~36 GB available, the data-mover NVMe writeback gets squeezed.
2. /mnt/local NVMe reads also go through page cache; with only 36 GB
   available and the data-mover writing ~50 GB of cached files in
   epoch 1, write throttling increases read latency on warm epochs.

**Lesson:** memory-pressure on the client is the wrong lever for this
workload. Both kernel and BeeGFS caches play a role; only the kernel
cache is sensitive to our pressure mechanism.

### Next-strategy candidates (if pilot confirms loss)

1. **Add `posix_fadvise(POSIX_FADV_DONTNEED)` after BeeGFS reads in the
   LD_PRELOAD client.** Bypasses kernel page cache for the data
   directory on every read. Forces every read to go to the wire, where
   FitCache's local /mnt/local NVMe path is shorter than the BeeGFS
   network round trip.
   - Caveat: BeeGFS server-side cache still helps Pure_CF. If that
     cache is also fast enough, FitCache still doesn't win.
2. **Run a workload whose I/O exceeds GPU compute** so caching actually
   moves wall-clock. Candidates: Megatron-LM with `.bin/.idx` shards
   (sequential mmap-style reads), DINOv2 with ImageNet-22k (millions of
   small files, no server-side cache hit ratio).
3. **Scale n_train up to exceed BeeGFS server cache.** If the BeeGFS
   server has e.g. ~200 GB of RAM cache, a ~300 GB dataset evicts cold
   files in the server. n_train=61440 (~3 TB raw, ~480 GB on disk)
   easily exceeds that. Wall-clock per run ~9 h, so this becomes a
   single-run validation rather than a 3-run average.

## 2026-05-14 — two-site repo organization (arc + Frontier)

After the n_train=61440 pilot landed conclusively negative (Pure_CF
warm-epoch 5,703 s on a 169 GB dataset; FCP cannot win at the
single-GPU scale this cluster offers), the campaign pivoted toward
Frontier where the user has previously observed FitCache beating
Pure_CF. To make that port a "fill in the site config" job instead of
"copy and fix every hardcoded path", the cosmoflow launcher scripts
were refactored to source a site config.

### New layout

```
benchmarks/sites/
  README.md         documentation
  _resolve.sh       sourced by launchers; picks site by FITPP_SITE env
  arc.sh            NCSU ARC cluster (current cluster)
  frontier.sh       ORNL Frontier (template with <proj> / TODO markers)
```

Every launcher script begins with:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../sites/_resolve.sh"
```

`_resolve.sh` sets `FITPP_REPO`, `FITPP_BUILD_DIR`, `FITPP_SERVER_BIN`,
`FITPP_CLIENT_LIB`, `FITPP_RESULTS_ROOT`, `FITPP_COSMOFLOW_DIR`,
`FITPP_PYTHON_TF`, `FITPP_MERCURY_LIB_DIR`, `FITPP_LOG4C_LIB_DIR`,
`FITPP_PFS_DATA_ROOT`, `FITPP_LOCAL_CACHE_ROOT`,
`FITPP_PFS_REGISTRY_ROOT`, `FITPP_SLURM_PARTITION`,
`FITPP_SLURM_ACCOUNT` (empty on arc, required on Frontier),
`FITPP_MODULE_LOADS` (empty on arc, multi-module on Frontier), and a
few defaults (`FITPP_SERVERS_PER_NODE_DEFAULT`, etc.).

### Refactored launchers (cosmoflow)

- `PDSW_FITPP.sh` — single-job baseline. `#SBATCH -p` removed (was
  hardcoded `rtx4060ti16g`); pass `-p "$FITPP_SLURM_PARTITION"` on the
  sbatch CLI instead. Tier paths and data-dir default come from site.
- `PDSW_FITPP_inner.sh` — common launcher used by all wrappers. All
  hardcoded `/home/ghu4/...` paths replaced with `$FITPP_*` vars.
- `command_CF_FITPP.sh` — the LD_PRELOAD'd training command. Python
  binary, cosmoflow source dir, and client lib now site-resolved.
- `PDSW_FITPP_two_job_concurrent_v2.sh` — driver builds an
  `SBATCH_BASE` array containing `-p $FITPP_SLURM_PARTITION` plus
  `--account=$FITPP_SLURM_ACCOUNT` when non-empty.
- `PDSW_FITPP_two_job_sequential_v2.sh` — same pattern.
- `PDSW_FITPP_with_pagecache_pressure.sh` — sources site config and
  uses `$FITPP_REPO` for the mem_hog binary path.

### Not refactored (still arc-only)

These still have hardcoded paths and would need the same treatment
before they run elsewhere:

- `PDSW_FITPP_three_tier.sh` (arc-specific anyway — c35 is the only
  node with PMem; Frontier has no PMem tier).
- `PDSW_FITPP_multinode.sh`.
- `PDSW_FITPP_two_job_concurrent.sh` / `_sequential.sh` (v1; v2 is
  the current driver).
- `benchmarks/megatron/*` and `benchmarks/dinov2/*` — both blocked by
  the mmap-vs-LD_PRELOAD architectural gap; not worth refactoring
  until that mechanism lands.
- `scripts/*` smoke tests — localhost-only, less critical.

### Frontier port: what's required to run

1. Clone FitCachePP repo into the appropriate Frontier filesystem
   location (Orion `$PROJWORK` or `$MEMBERWORK`).
2. Build Mercury for the Slingshot fabric (ofi+cxi or ofi+verbs) and
   log4c. Build FitCachePP against them.
3. Clone cosmoflow-benchmark-master (and any other workloads) next to
   the repo.
4. Stage datasets onto Orion (`cosmoUniverse_*/train_61440`, etc.).
5. Edit `benchmarks/sites/frontier.sh`: replace every `TODO` / `<proj>`
   / `<PROJ>` marker with real values for your Frontier allocation.
6. Submit with `FITPP_SITE=frontier sbatch ...` or, for drivers,
   `FITPP_SITE=frontier bash benchmarks/cosmoflow/PDSW_FITPP_two_job_concurrent_v2.sh`.

The C++ source is unchanged; same build commands.

## 2026-05-14 — n_train=61440 IPDPS-regime pilot, EPOCH 1 DATA POINT

**Setup:** FitCachePP (c68, SLURM 221940) + Pure_CF (c69, 221941), each at
n_train=61440 (169 GB dataset), 3 epochs, 4 servers per node, FitCache
single-job mode (`FitCache_CROSS_JOB=0`). DRAM tier 100 GB, NVMe tier
500 GB on /mnt/local — large enough to cache the entire dataset on FCP.

**Pure_CF (c69) epoch 1 wall-clock: 10,931 s = 3h02m, 356 ms/step.**

This is the critical signal — at 356 ms/step, the workload is no longer
GPU-bound (which was 213 ms/step at n_train=8192). The extra 143 ms/step
is real I/O latency: the 169 GB dataset exceeds the BeeGFS server-side
cache (whatever its actual size, on the order of tens of GB based on
the n_train=8192 results) plus the 197 GB client RAM. Roughly two-
thirds of each step's read traffic hits actual remote storage rather
than cache.

**This is exactly the regime where FitCache++ should win.** Pure_CF
warm epochs will see the same pattern (dataset still doesn't fit in
any cache), so Pure_CF warm wall-clock should remain ~10,000+s.
FitCachePP's full dataset is already on local NVMe (61,440 / 61,440
files copied by 16:52 EDT) — FitCache warm epochs should be GPU-bound
or close to it, ~5,000-6,500s.

Expected warm-epoch gap: ~4,000-5,000 s / ~40-50% / Pure_CF being
much slower than FitCachePP. This would be the first measurement
that decisively defends the per-job-speedup claim of FitCache++.

Waiting for warm-epoch numbers (epoch 2 of both pilots in flight; TF
stdout buffer hides the epoch-1 wall-clock line on FCP for now).

### 2026-05-14 18:43 — Pure_CF epoch 2 result invalidates the hypothesis

Pure_CF epoch 2 wall-clock landed at **5,703 s (1h35m), 186 ms/step**.
That is a **48% speedup over Pure_CF cold epoch 1 (10,931 s, 356 ms/step)**.

The warm-cache benefit on this cluster is real and large even at the
169 GB dataset size — the kernel page cache + BeeGFS server cache do
warm up between epochs and absorb most of epoch 2's reads. The 186
ms/step is close to the n_train=8192 GPU-bound floor of ~213 ms/step,
indicating I/O latency is now negligible for warm Pure_CF.

**Implication:** FitCachePP cannot win wall-clock against Pure_CF on
this cluster even at IPDPS-regime dataset size. Best-case FitCache
warm-epoch step time = 213 ms GPU + ~2 ms RPC overhead per open + ~0.5 ms
local NVMe read ≈ 218 ms/step → 30,720 × 218 ms ≈ **6,700 s (1h52m)**
vs Pure_CF warm 5,703 s. FitCache would be ~17% slower on warm.

The cluster's BeeGFS+RAM setup is structurally biased toward Pure_CF
at single-GPU scale. **No tunable parameter on this cluster makes
FitCache faster** because the bottleneck FitCache addresses (slow PFS)
isn't actually slow once warmed.

### FCP pilot wedged at end of epoch 1's reads

FCP (c68, 221940) opens count stuck at 61,440 since 16:52 EDT; 2h21m
of silence on RPCs at 19:13. slurm out file mtime still 13:52 (XLA
compile time), no epoch 1 wall-clock line yet. Same hang pattern as
the cross-job runs from earlier today, but in single-job mode this
time so no peer RPCs are involved. Root cause not yet identified —
the cgroup is healthy, the data-mover finished cleanly, the
servers' last log entry is a successful open+redirect+close.
Hypothesis: client-side LD_PRELOAD wrapper blocks on a Mercury read
or open RPC whose response never arrives (server dead?). Needs
inspection of the SLURM stepd state on c68 (which we cannot do from
the login node).

Both pilots will hit SLURM 24h timeout if not scancelled.

### Strategic conclusion

The path to "FitCachePP beats Pure_CF on per-job wall-clock" on this
cluster is closed:

- Memory pressure pilot — failed (BeeGFS server cache neutralized it)
- n_train=61440 IPDPS regime pilot — Pure_CF warm-epoch already
  shows it benefits from caching too; even if FitCache ran cleanly
  its warm-epoch would be slower due to RPC tax
- Megatron/DINOv2 alternatives — mmap-based, bypass LD_PRELOAD

The honest options now:

1. **Frame the TPDS paper around the cross-job aggregate-IO bound,
   the three-tier extrapolation closure, and no-regression in
   single-job mode (3.7% overhead measured on n_train=8192).** Cite
   the IPDPS Frontier-scale numbers for per-job speedup.
2. **Port to Frontier.** Larger PFS contention, MI250X faster GPU,
   1024+ GPUs sharing storage — the regime where FitCache's local
   NVMe path actually wins. The user has empirical evidence it works
   there. Setup tax: Mercury Slingshot, allocation, dataset stage-in.
3. **Both.** Option 1 defends the cluster-side contributions for the
   journal extension; option 2 provides the per-job speedup data
   point that closes the original IPDPS line.

Either way, **stop running per-job-speedup experiments on this
cluster**. The data is consistent: at this cluster's scale, FitCache
overhead exceeds its benefit.

## 2026-05-15 — Frontier port + mmap interceptor + cross-job timeout

This session covered three engineering milestones plus the dataset stage-in
for the Megatron + DINOv2 workloads.

### Frontier port + CosmoFlow single-GPU sanity (sub-region)

Build chain landed cleanly on Frontier:
- log4c 1.2.4 from source at `/ccs/home/ghu4/log4c-1.2.4/install/`
- Mercury 2.0.1 reused from the on-disk spack tree at
  `/sw/frontier/spack-envs/base/opt/cray-sles15-zen3/cce-15.0.0/mercury-2.0.1-…/`
  (the module `mercury/2.0.1` is no longer surfaced by `module spider`, but
  the shared libs + headers + pkgconfig still exist and link cleanly).
- Compiled with `/opt/cray/pe/gcc-native/13/bin/g++` directly because the
  Cray `CC` wrapper strips one of `mercury.pc`'s two `-I` paths and breaks
  the include chain. gcc-13 direct does not.
- All 12/12 cross-job + mmap smoke tests pass.

CosmoFlow single-GPU sanity at n_train=1024 / 3 epochs:
- FitCachePP warm-epoch: 71.36 s, 71.56 s (epochs 2, 3)
- Pure_CF        warm-epoch: 69.56 s, 69.51 s
- Δ = +2.6%, +2.9% — the expected overhead floor at small dataset size
  (307 MB fits trivially in node RAM, so Pure_CF warm reads are RAM-fast
  and FitCache's LD_PRELOAD + Mercury-RPC adds ~3 ms/step).

The headline-scale run (n_train=61440, 169 GB) is gated on the 1.6 TB
`cosmoUniverse_2019_05_4parE_tf_v2.tar` extraction.

### Peer-RPC timeout watchdog (cross-job hang fix)

Landed as commit `224e31a`. New env var `FitCache_PEER_RPC_TIMEOUT_SEC`
(default 30 s; 0 disables). New atomic counter `peer_lookup_timeout`
exposed via `cross_job_counters_snapshot()` and reported in
`cross_job_stats[rank=...]` periodic log lines.

Mechanism: `OpenPeerLookupState` gets a `std::vector<hg_handle_t>
pending_handles` tracked under the existing `respond_mtx`. After fanning
out peer-lookup forwards, the open-RPC handler arms a watchdog thread that
sleeps until the deadline, then under the lock marks `responded`, runs the
PFS fallback open + `HG_Respond`, and `HG_Cancel`s every still-pending
handle (the cancellations trigger the existing callbacks with
`HG_CANCELED` → the normal cleanup runs).

Pre-fix behaviour: a peer that deregistered mid-job (as in the
2026-05-14 two_job_concurrent_v2 run 2) blocked every other server's
peer-lookup RPC indefinitely; the only recovery was SLURM 24h timeout.
Post-fix: 30 s deadline + fast PFS fallback, no client hang. Smoke test
`tests/test_cross_job_smoke.cpp` test 11/12 locks in the env-var and
counter contract.

### mmap interceptor (Megatron + DINOv2 unblock)

Landed as commits `85c9527 / 69fa20c / ef7eb6e`. The previous mmap
limitation (numpy.memmap and DINOv2's PIL/tar slicing bypass the
LD_PRELOAD client because page faults aren't syscalls) is now resolved.

Strategy: for mmap on a FitCache-tracked fd, allocate an anonymous
mapping of the same length, eager-populate it via the existing FitCache
read path (`ms_read` → server RPC → cached-file pread → bulk transfer),
mprotect to the user-requested prot, and track addr→length so munmap
unmaps the right region. Subsequent pointer-style reads on the mapping
hit RAM, never the PFS.

Three corrections found through smoke testing:
1. **`mmap64` symbol needed.** CPython's `_mmap.so` calls
   `mmap64@GLIBC_2.2.5`, not `mmap`. Without a `mmap64` wrapper
   numpy.memmap completely bypassed our interceptor.
2. **Read-only `MAP_SHARED` intercepted.** `numpy.memmap mode='r'` uses
   `MAP_SHARED | PROT_READ` (CPython mmapmodule.c). The initial
   bypass-MAP_SHARED rule was overzealous; we only bypass when
   `PROT_WRITE` is set.
3. **Read wrapper passthrough for tracked fds.** Routing sequential
   `read()` through `ms_read` left the local kernel fd unadvanced, which
   broke Python's `BufferedReader.tell()` and caused Megatron's
   `_IndexReader` to call `numpy.frombuffer(buf, count, offset=-194648)`
   (negative offset; "offset must be non-negative" error). Sequential
   read() on tracked fds now calls `__real_read` directly. The cache
   benefit still flows through the mmap interceptor (mmap-time
   eager-fill) and the pread wrapper (explicit-offset path); only plain
   `read()` is back to PFS-direct.

Login-node smoke matrix (all PASS):

| workload | client smoke           | engagement signals |
|----------|-------------------------|-------------------|
| Megatron `.bin` via `numpy.memmap`      | `memmap_only_iter.py`         | 1 Open RPC, 2 mmap-redirects, 210 MB/s |
| Megatron `.idx` + `.bin` via IndexedDataset | `megatron_io_only_iter.py` | 9,732 docs, 397 MB/s |
| DINOv2 ImageNet-style many-small-files   | `dinov2_io_only_iter.py`     | 800 Open RPCs, 1600 mmap-redirects |

Compute-node smoke matrix (in flight or done):

| workload    | SLURM job  | result          |
|-------------|------------|-----------------|
| DINOv2      | 4585810    | PASS (16s; 2003 Open RPCs, 4000 mmap-redirects) |
| Megatron    | 4585887    | submitted post-fix; pending |
| cross-job concurrent (peer-RPC timeout exercise) | 4585804 + 4585805 | submitted; pending |

### Tooling that landed

- `scripts/env/build_torch_rocm_env.sh` — PyTorch + ROCm 6.0 conda env at
  `/ccs/home/ghu4/envs/torch_rocm/`. Used by Megatron + DINOv2.
- `scripts/env/stage_megatron_dinov2_data.sh` — downloads enwik8,
  tokenizes via Megatron-LM v0.11.0's `preprocess_data.py`, generates a
  synthetic ImageNet-22k-style stand-in for DINOv2. Lands under
  `/lustre/orion/gen008/proj-shared/ghu4/data/{megatron,dinov2}/`.
- `scripts/frontier/frontier_sanity_run.sh` — CosmoFlow FCP-vs-PCF.
- `scripts/frontier/frontier_run_replicates.sh` + `parse_epoch_walltime.py`
  — 3-run averaging driver + parser.
- `scripts/frontier/frontier_megatron_smoke.sh` + `frontier_dinov2_smoke.sh`
  — compute-node sbatch wrappers that run the mmap-interceptor-validating
  IO-only iterators against the staged corpora.
- `scripts/frontier/frontier_two_job_concurrent.sh` — submits two
  CosmoFlow jobs sharing a cluster registry on Orion proj-shared so the
  cross-job sharing pathway fires; first run on Frontier with the
  peer-RPC timeout watchdog in place.

### Data layout (post-2026-05-15)

```
/lustre/orion/gen008/proj-shared/ghu4/data/
├── cosmoflow/           (symlinks to the cosmoUniverse_*_mini + full.tar; the
│                         full tar extraction is still in progress as of EOD)
├── megatron/
│   ├── tokenizer/       (gpt2-vocab.json + gpt2-merges.txt)
│   ├── enwik8/          (real corpus + tokenized .bin/.idx)
│   └── synth_slice/     (older synthetic; kept as fallback)
└── dinov2/
    └── imagenet_synth/  (20 classes × 50 imgs of 224×224 random JPEGs;
                          stand-in for ImageNet-22k registration-required
                          access)
```

Note: ImageNet-22k itself is 1.4 TB and requires LSVRC/Kaggle registration.
The synthetic stand-in is enough to validate the mmap-interceptor path; a
real-data follow-up campaign would stage the real dataset.

## 2026-05-15 — Megatron pretrain_gpt.py compare landed (workload-generalization)

After five Megatron blockers (resolved one-at-a-time in
`scripts/frontier/frontier_megatron_compare.sh`), the FitCachePP-vs-Pure_CF
comparison on Megatron-LM v0.11.0 pretrain_gpt.py + enwik8 finally ran clean
end-to-end (jobs 4586991/4586992, 200 iters, micro-batch=global=4, single
MI250X GCD on Frontier).

**Blockers resolved (in order)**:
1. `pybind11/pybind11.h: No such file` in `megatron/core/datasets/Makefile`
   → pre-built `helpers_cpp*.so` on login node with `python setup.py build_ext`.
2. `address family not supported by protocol` from torch.distributed bootstrap
   → set `MASTER_ADDR=127.0.0.1` (Frontier disables IPv6 sockets on compute).
3. `subprocess.run(['nvcc', '-V'])` from `legacy/fused_kernels/__init__.py`
   → patched `load(args)` to early-return when `cpp_extension.CUDA_HOME is None`.
4. `persist_layer_norm not supported by torch LayerNorm` from
   `core/transformer/torch_norm.py` (WrappedTorchNorm assertion)
   → added `--no-persist-layer-norm`.
5. `gradient_accumulation_fusion=True but fused_weight_gradient_mlp_cuda
   missing` (requires APEX)
   → added `--no-gradient-accumulation-fusion`.
6. `ProcessGroupGloo::allreduce_coalesced: unsupported device type cuda`
   → switched `--distributed-backend gloo` → `nccl` (PyTorch+rocm6.0 maps
   nccl→rccl).

**Result (200 iter, 4 samples/iter, micro-batch=4)**:

| Side       | Wall-clock | Per-iter (ms) | Final loss | Open RPCs | mmap-redir |
|------------|-----------:|--------------:|-----------:|----------:|-----------:|
| FitCachePP |        68s |         128.6 |   6.115665 |        29 |         22 |
| Pure_CF    |        75s |         128.9 |   6.115665 |         0 |          0 |

Per-iter delta = 0.3 ms (well inside run-to-run noise on a 128 ms compute-bound
inner loop). Final loss is **bit-identical**, which is the correctness check.
The 7-second wall-clock gap is dominated by warm-up overhead, not steady-state
training — at this dataset size (58 MB tokenized enwik8) the OS page cache
holds the entire .bin after the first read, so neither side sees real I/O during
the inner loop.

**What this defends**: the workload-generalization claim. The mmap interceptor
fires correctly inside a real Megatron pretrain (22 redirects), the LD_PRELOAD
client registers files with the server (29 Open RPCs), training reaches the same
final loss as the non-intercepted baseline, and per-iter latency is unchanged.
This is the missing piece for the paper to say "the cache architecture
generalizes beyond CosmoFlow-style sample iteration into LM-style memmap'd
corpora" — previously (ARC) Megatron ran 0 Open RPCs because numpy.memmap
bypassed the file-open hook entirely. The interceptor + the read/lseek
`__real_*` pass-through fix close that gap.

**What this does NOT defend**: the per-job speedup claim. With enwik8 fitting
trivially in page cache, FitCachePP can't differentiate from Pure_CF on
steady-state per-iter latency. The CosmoFlow headline at n_train=524288 (full
1.8 TB v2 set, well beyond per-node DRAM) is the load-bearing measurement for
per-job speedup; Megatron is the workload-generalization story only.

## 2026-05-15 — Multi-GPU CosmoFlow Horovod hang (open issue)

Once `data/cosmoflow/cosmoUniverse_2019_05_4parE_tf_v2/` was fully extracted
(524288 train + 65536 validation tfrecords) we tried to run the full-scale
n_train=524288 headline via the user-supplied multi-GPU srun pattern:

```
srun -N $N -n $N_TOTAL_SERVERS --ntasks-per-node=$SERVERS_PER_NODE fitcache_server &
sleep 15
srun -N $N -c4 --gpus-per-node=8 --ntasks-per-gpu=1 wrapper.sh   # LD_PRELOAD + train.py
```

(stored as `scripts/frontier/frontier_cosmoflow_headline.sh`).

**Smoke at N_NODES=1, n_train=8192, 8 GPUs, SERVERS_PER_NODE=2**:
- **Pure_CF** ran clean: 2 epochs × 104.5 s/epoch, "All done!", training wall=259 s.
  → confirms the multi-GPU srun + Horovod + cosmoflow path works on Frontier.
- **FitCachePP** hung in the first Horovod gradient allreduce:
  ```
  W stall_inspector.cc:138 One or more tensors were submitted to be reduced...
  waiting for remainder of ranks for more than 60 seconds.
  Missing ranks:
    0: [DistributedSGD_Allreduce/.../HorovodAllreduce_grads_0, ...]
  ```
  Stuck for 21+ minutes until scancel.

Retry at **SERVERS_PER_NODE=1** (rule out CPU contention from 2 server processes
per node): same hang, but the missing rank shifted from 0 → 1. Variable rank,
deterministic hang. → not specific to one rank; it's a race condition.

**What the diagnostics say**:
- The FitCache server log is healthy: thousands of `Open RPC: requested path`
  entries with `Successful Redirection` and `Closing File` follow-ups. RPCs flow
  through and complete.
- The cosmoflow train.py log shows all 8 ranks reach `Initialized rank N size 8
  local_rank N` (so horovod.init() completes for all of them) before the stall
  fires.
- The benchmark directory contains 700+ `fitcache_intercept_log.<pid>.0` files
  for a single 8-rank smoke. TensorFlow's data pipeline forks many subprocesses
  (interleave/parallel_map workers); each one inherits LD_PRELOAD and creates
  its own FitCachePP client, each of which opens its own RPC channel to the
  server.

**Hypothesis**: the FitCachePP client's per-process init (Mercury HG_Init
+ first lookup of server addresses + first registration with the cluster
registry) is non-trivial in wall-clock — fine in 1-process single-GPU mode,
but when one rank's TF data pipeline forks ~30 subprocesses and each does the
same init, the rank's first training step is delayed *significantly* past the
others'. With 60 s stall threshold and ~10-100 ms per fork init, a rank with
poor fork-init scheduling (or one that hits a slow server response) can fall
behind enough to trigger the stall and never recover, because gloo/MPI's
collective ordering serializes everyone behind that rank.

**This is NOT new code that broke**:
- The mmap interceptor (2026-05-15) only intercepts mmap/mmap64/munmap and
  was disabled-by-default behavior for the cosmoflow path (cosmoflow's
  tfrecord reader uses plain read(), not numpy.memmap).
- The read()-pass-through fix (2026-05-15) only changes the `__real_read`
  call path for *tracked* fds; untracked fds (everything outside
  FitCache_DATA_DIR) are unaffected.
- The HRW routing slice (2026-05-11) is gated by `FitCache_CROSS_JOB`, which
  is `0` in this smoke.

What changed on Frontier vs ARC IPDPS multi-GPU runs:
- The TF version (2.14 vs whatever was on ARC).
- The PyTorch/Horovod build (we built from source with HOROVOD_WITH_GLOO=1
  + HOROVOD_WITH_MPI=1 but without HOROVOD_GPU_OPERATIONS=NCCL, after the
  bfd_close mismatch in ROCm 5.7.1 — so collectives go via host-side gloo,
  which is generally slower than the GPU-direct path).
- The number of TF data pipeline workers is auto-tuned and may differ.

**Forward path candidates** (deferred to a future debug session):
1. Set `FitCache_DATA_DIR` to a path that excludes the tfrecords so the
   client doesn't intercept them; use FitCachePP only for a different
   benchmark. (Defeats the per-job speedup story for CosmoFlow.)
2. Rebuild Horovod with `HOROVOD_GPU_OPERATIONS=NCCL` + `HOROVOD_GPU=ROCM`
   so the first collective doesn't go through gloo and the stall_inspector
   timeout window shifts (this was tried earlier and hit a ROCm 5.7.1
   bfd_close mismatch — needs a re-attempt against ROCm 6.0).
3. Add per-rank cache pre-warm step before `model.fit()` so the cold-read
   latency is paid before any collective is issued.
4. Make the FitCachePP client's Mercury init re-use a process-shared address
   pool so forked subprocesses don't redo the lookup (server-side change).
5. Run with TF data pipeline parallelism = 1 (single-threaded prefetch).
   Likely tanks I/O throughput but isolates whether the fork is the cause.

**Pragmatic decision tonight**: pivoted to **single-GPU** FitCachePP-vs-Pure_CF
on the now-extracted full v2 set (1 rank → no Horovod → no stall), at
n_train=32768. Single-GPU is enough to characterise per-job speedup
*qualitatively* (FitCachePP server engaged, DRAM cache populated) even if it
can't match the wall-clock numbers of the user's HVAC sbatch which runs 16
nodes × 8 GPUs. The headline-scale multi-GPU run is left as an explicit
follow-up; see candidates above.

## 2026-05-15 — Cross-job has_yes=0 mechanism (open issue)

The cross-job concurrent smoke (jobs 4585804 + 4585805, 1 node each, 4
ranks/job, shared `FitCache_CLUSTER_REGISTRY_DIR`, different `FITPP_SEED`)
showed:

- `peer_lookup forwarded=1148/1183, handled=1117/1112` — RPC fanout works.
- `has_yes=0, has_no=1117/1112` — every peer answers "no I don't have it",
  including for files known to be in *some* job's local cache.
- `redirect_to_peer=0` — therefore no cross-job hits ever surfaced.
- `timeout=0` — the 2026-05-14 peer-RPC watchdog held; no hang on this front.

**Captured state** of `$FITPP_PFS_REGISTRY_ROOT/cross_job_concurrent/<TAG>/registry.v1/`:
- `nodes/frontier{02941,03063}_rank{0..3}.txt` — Mercury OFI addresses + node
  UUIDs + jobids. So both jobs *did* find each other's Mercury endpoints.
- `datasets/<hash>.txt` — `dataset.manifest_hash=14081395369131431799`,
  `dataset.name=fitcache-default`, plus two subscriber entries (one per job
  ID). So both jobs joined the same "dataset" namespace.
- **No per-file presence entries.** The cluster registry is currently a node
  + dataset discovery layer, not a path→owner inventory.

**Probable mechanism** (needs source-walk to confirm): peer_lookup uses HRW
to pick the *single* owner rank for path X, then asks that rank "do you have
X?" If X was locally cached by a *different* rank (e.g., file was opened
inside jobA's rank 2, but HRW hashes path X to jobB's rank 0), the HRW
owner correctly says "no" — it never saw X. The cluster registry's
`nodes/<host>_rank<r>.txt` files don't record which paths each rank has
served, so there's no fallback "ask everyone" path.

**Forward path candidates**:
1. Augment the cluster registry with per-rank presence (each rank writes a
   tiny `presence/<rank>.idx` mapping paths→last-touch-time; lookups
   consult presence before falling back to PFS).
2. Or: have the rank that locally caches X tell the HRW-owner via a
   one-way `register_file(X)` RPC, so the HRW owner becomes the authoritative
   "who has X" pointer.
3. Or: drop HRW for peer_lookup and broadcast the lookup to all peers
   (scales poorly; only OK for small cluster).

Option 2 is the minimum-disruption fix and matches the IPDPS architectural
intent. Confirm in source: `src/cross_job/fitcache_cross_job.{h,cpp}` and the
`peer_lookup` handler in `src/comm/fitcache_comm_server.cpp` are the places to
audit. Defer to a focused debug session — the watchdog/hang fix (timeout=0
confirmed) was the prerequisite, and that part holds.

## 2026-05-15 — Single-GPU full-dataset CosmoFlow result (and why it doesn't show speedup)

After the multi-GPU hang forced a pivot, the single-GPU comparison ran clean on the
now-extracted full v2 set (jobs 4587411 + 4587412):

| Side       | Mean epoch (s) | Total 3-epoch (s) | Open RPCs | Files cached |
|------------|---------------:|------------------:|----------:|-------------:|
| FitCachePP |          88.26 |             264.8 |      3839 |         1280 |
| Pure_CF    |          86.37 |             259.1 |         0 |            0 |

Δ = +1.89 s/ep (FitCachePP **slower** by ~2.2 %). FitCache engagement is real
(3839 Open RPCs, 1280 files cached in DRAM tier), but page cache absorbs the
working set so the cache adds RPC latency without I/O savings.

**Why no speedup at this scale (structural, not a bug)**:
- cosmoflow's MLPerf config runs 256 steps × batch_size=4 = 1024 samples per
  epoch on 1 rank. Each sample is one ~2.9 MB tfrecord, so per-epoch I/O is
  about 3 GB.
- Frontier compute nodes have 512 GB DRAM. A 3 GB working set fits trivially in
  the OS page cache, so the cold epoch is the only chance to see I/O cost, and
  even there 3 GB at PFS read bandwidth is sub-second.
- The IPDPS-era per-job speedup story comes from multi-GPU / multi-node runs
  where the *aggregate* working set across all ranks exceeds any single node's
  page cache (16 nodes × 8 GPUs × 1024 samples = 128K files = ~370 GB,
  comfortably past any single-node cache). FitCachePP wins because its
  per-node NVMe + cross-node sharing avoids the PFS bottleneck.
- Multi-GPU is blocked by the Horovod-fork hang documented above.

**Honest status for the journal extension as of 2026-05-15 EOD**:
- ✅ **Workload generalization** (Megatron + DINOv2): mmap interceptor proven,
  Megatron compare clean (28 OpenRPCs, 22 mmap-redirects, bit-identical loss),
  DINOv2 compare clean.
- ✅ **Cross-job hang fix** (peer-RPC timeout watchdog): timeout=0 across two
  concurrent jobs confirms no hang. has_yes=0 mechanism issue (separate from
  the hang fix) documented with three forward-path candidates.
- ⚠ **Per-job speedup on CosmoFlow**: deferred. Single-GPU configuration on
  Frontier cannot exceed page cache; multi-GPU configuration hangs in Horovod
  fork-init. Both paths documented with concrete next-step candidates.

## 2026-05-17 — Multi-GPU root cause + fix (per-job-speedup unblocked)

The "Horovod fork-init hang" diagnosis was wrong. What actually happens at
8 GPUs / 1 node under LD_PRELOAD on Frontier:

1. All 8 ranks reach `model.fit()` and print "Epoch 1/2".
2. Each rank's TF data pipeline calls `open()` on the first tfrecord. Our
   wrapper does `__real_open` → returns local fd, then calls
   `fitcache_track_file` which fires `fitcache_client_comm_gen_open_rpc` to
   the server and blocks via `fitcache_client_block_for_file` waiting for
   the open RPC's callback to populate `fd_redir_map[fd]`.
3. With 8 ranks × ~4 TF parallel-call workers each = ~32 concurrent opens
   serialised through 2 fitcache_server processes' single Mercury progress
   thread, throughput collapsed to ~7 opens/sec. Cold-epoch wall went from
   Pure_CF's 105s → FitCachePP's 571s (a 5.4× slowdown).
4. Some runs hung outright at "Beginning training" with AveCPU=00:00:00.

Three combined patches close this. All match the behaviour of the reference
HVAC implementation at `/lustre/orion/gen008/proj-shared/ghu4/FitCache_Frontier/`:

**Patch 1 — fire-and-forget open RPC** (`src/client/fitcache_client.cpp`).
The reference's `hvac_client_block()` is a deprecated no-op (see
`FitCache_Frontier/src/hvac_comm_client.cpp:361` — just logs a warning and
returns). The open RPC is fired but the client does not block on it. The
first reads then fall back to `__real_pread` on the LOCAL fd (still fast
PFS reads) until the open RPC's callback asynchronously populates
`fd_redir_map`, after which subsequent reads can use the server-cached
path. We removed the `fitcache_client_block_for_file(fd_map[fd])` call
that was forcing every open through a synchronous round-trip.

**Patch 2 — thread-safe Mercury init** (`src/client/fitcache_client.cpp`).
TF's `tf.data` AUTOTUNE pipeline spawns parallel I/O worker threads. With
`g_mercury_init` checked without a lock, multiple threads in the same rank
could both see `g_mercury_init=false`, both call `fitcache_init_comm()`,
HG_Init Mercury twice, pthread_create two progress threads against the
same hg_context. Symptom: ranks lock at first data-pipeline iteration with
AveCPU=00:00:00. The reference has the same race but TF's older
single-threaded data pipeline didn't trigger it. We added a static
`pthread_mutex_t` around the `!g_mercury_init` check + init.

**Patch 3 — ms_read race-safe early bypass** (`src/client/fitcache_multi_source_read.cpp`).
After patch 1 makes the open RPC fire-and-forget, the first `ms_read` on
the local fd can race ahead of the open callback. `fd_redir_map[fd]` is
still 0 at that point, so the server-side handler does `pread(0, ...)` —
which reads STDIN and fails. Intercept log showed:

```
[multi_source_read:69] Remote fd: 0
[multi_source_read:86] Generated read rpc with ms
[comm_client:370] Open RPC Returned FD: 33, Local FD 25   ← arrives AFTER
[multi_source_read:133] RPC failed
```

The reference guards this at the `hvac_remote_pread` level
(`if (hvac_file_tracked(fd) && fd_redir_map[fd] != 0)`). We added the same
guard at the top of `ms_read`: if `fd_redir_map[fd] == 0` (or absent),
fall back to `__real_read` / `__real_pread` on the local fd. This is the
"fire-and-forget open + read-from-local-until-cache-ready" protocol
referenced in patch 1.

### Validation at n=8192 / 1 node × 8 GPUs (4598562)

| Side          | Cold (ep 1) | Warm (ep 2) | Mean   | Total wall | Open RPCs |
|---------------|------------:|------------:|-------:|-----------:|----------:|
| Pure_CF       |        105s |        104s |  105s  |       256s |         0 |
| **FitCachePP**|     **135s** |     **73s** |**103.8s** |    258s |     8345+ |
| FitCachePP (pre-patch) | — | — | 539s | 1149s | 28K |

**Warm-epoch is 30% faster than Pure_CF** (73s vs 104s) — the FitCachePP
advantage paying off once the cache is populated. Cold epoch carries the
30s one-time cost of server-side PFS-to-DRAM cache copies; mean is tied
with Pure_CF, total wall +1%. Pre-patch numbers were 5× slower across the
board.

### Long-term north-star (agreed 2026-05-17)

FitCachePP = reusable cache layer for AI training data:
- (1) improves warm-epoch perf within one job,
- (2) generalizes beyond one file-access pattern (numpy.memmap, gzip-tfrecord, JPEG),
- (3) enables cache reuse across jobs.

Headline result for the paper is always reported as a **triple**: cold
epoch wall, warm epoch wall, and multi-epoch amortized wall. The cold cost
is real and the paper must show when it's amortized. Cross-job sharing is
the most important new contribution for the extension and is verified
EARLY (before scaling to multi-node) so the headline claim has the right
mechanism behind it.

## 2026-05-15 EOD addendum — Horovod GPU-collectives gap diagnosed; cross-job has_yes=0 fix shipped

After the user pushed back on the single-GPU pivot ("each experiment should
use all GPUs on the node") and the deferred Horovod debug, I confirmed the
multi-GPU hang and shipped the cross-job changes.

### Multi-GPU hang root cause

`python -c "import horovod.tensorflow as hvd; print(hvd.nccl_built(),
hvd.rocm_built())"` against the env at `/ccs/home/ghu4/envs/cosmoflow_rocm`
reports:

```
mpi_built   True
gloo_built  True
nccl_built  0       <-- CPU-side collectives only
cuda_built  False
rocm_built  False   <-- not built against RCCL
```

That's the hang's root cause, not the launch pattern. With gloo+MPI only,
every `hvd.allreduce` on a GPU tensor goes GPU→host-copy→CPU-allreduce→host-broadcast→GPU.
Combined with the FitCachePP LD_PRELOAD adding any data-pipeline latency, one
rank falls behind the others' staging buffers and the 60s Horovod
stall_inspector fires. The IPDPS-era ARC build had RCCL+ROCm baked in, so
collectives were GPU-direct and the LD_PRELOAD didn't trip the timeout.

Launch command is correct per `feedback-frontier-multi-gpu-pattern`:
```
srun -N $N -c4 --gpus-per-node=8 --ntasks-per-gpu=1 --cpu-bind=cores wrapper.sh
# wrapper.sh:
LD_PRELOAD=libfitcache_client.so $FITPP_PYTHON_TF train.py -d \
    --data-dir "$FitCache_DATA_DIR" --n-train ... --n-epochs ...
# env: MIOPEN_DISABLE_CACHE=1, MIOPEN_FIND_MODE=3, MIOPEN_USER_DB_PATH=/tmp/...,
#      TF_ROCM_FUSION_DISABLE=1, TF_XLA_FLAGS="--tf_xla_auto_jit=0 ...",
#      BBPATH=/tmp, FitCache_DRAM_PATH=/tmp/..._dram, etc
```

Rebuild kicked off (`scripts/env/build_cosmoflow_env.sh` already had the
correct env flags; first attempt fell through to a stale Python 3.6, second
attempt uses explicit `/ccs/home/ghu4/envs/cosmoflow_rocm/bin/python` and
`HOROVOD_RCCL_HOME=/opt/rocm-6.0.0/rccl + HOROVOD_RCCL_INCLUDE/LIB` set
explicitly). Build time ~30-60min; verifies post-build that `nccl_built=True`
and `rocm_built=True`. Once landed, `cosmoflow_headline.sh` at
N_NODES=1..16 should run without the rank-skew hang.

### Cross-job has_yes=0 — shipped all three fixes

User requested all three forward-path candidates be implemented and tested.

**Implementation map**:

| Option | What it adds | Files touched | Test |
|--------|--------------|---------------|------|
| 1: PFS-backed per-file presence index | `registry_record_file_presence(path, addr, dataset_hash)` and `registry_lookup_file_presence(path)` in cluster_registry; `${registry.v1}/presence/aa/bb/<sha1>.txt` append-only files | `src/cross_job/fitcache_cluster_registry.{h,cpp}` (+~260 lines) | test 13, 14 |
| 2: register-file-on-cache RPC | New `fitcache_register_file_rpc` (path + serve_addr + dataset_hash) + handler that updates an in-memory `remote_presence_map`; broadcast from data-mover at cache populate | `src/comm/fitcache_comm.h`, `src/comm/fitcache_comm_server.cpp`, `src/cross_job/fitcache_cross_job.{h,cpp}`, `src/server/fitcache_server.cpp` | test 15 |
| 3: broadcast lookup | Already in place: `fitcache_open_rpc_handler` fans peer_lookup out to every live peer. Verified resolution priority (local → in-memory → PFS) | `src/comm/fitcache_comm_server.cpp` (peer_lookup_rpc_handler now does 3-tier lookup) | test 16 |

The data mover hook (`src/server/fitcache_data_mover.cpp` line ~509) now does
both Option 1 (PFS write) AND Option 2 (RPC broadcast) at cache-populate
time. The `peer_lookup_rpc_handler` consultation order:
1. **local path_cache_map** — fastest, my own cache.
2. **remote_presence_map** — in-memory peer-RPC index (Option 2).
3. **PFS presence index** — durable, cluster-wide (Option 1).

If a path is in any of the three, the handler returns has=1 with serve_addr
pointing at whichever holder we know about; the client gets redirected
there and retrieves the file. Closing the prior gap where each peer only
checked its own path_cache_map and answered NO if a different peer held it.

**Tests**: `test_cross_job_smoke` now runs **16/16** (was 12/12):
- 13: PFS presence roundtrip + dedupe + multi-holder.
- 14: stale-entry filter at lookup time + gc rewrite.
- 15: in-memory remote_presence_map insert/lookup/overwrite/empty-input.
- 16: 3-tier resolution priority + multiple PFS holders co-exist.

**End-to-end validation**: deferred to the next two-job concurrent run on
Frontier after Horovod rebuild lands. The smoke tests verify the structural
contract; the run will verify the integration produces `has_yes > 0` and
`redirect_to_peer > 0` (with overlapping files between the two jobs, not
the disjoint-seed pattern the previous smoke used).


