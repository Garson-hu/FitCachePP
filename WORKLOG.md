# FitCache++ Worklog

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
- `PDSW_FITPP.sh` — single-job FitCache++ baseline (`FitCache_CROSS_JOB=0`)
- `PDSW_FITPP_inner.sh` — shared launcher (per-node servers + horovodrun)
- `PDSW_FITPP_two_job_sequential.sh` — Job B sbatched with `--dependency=afterok` after Job A
- `PDSW_FITPP_two_job_concurrent.sh` — both jobs sbatched in parallel on different nodes
- `command_CF_FITPP.sh` — horovodrun command body with `cd` to the cosmoflow benchmark dir
Committed locally as `8fb565e`.

**First cluster experiment landed:** single-job FitCache++ baseline on c66, SLURM 221607, 19m00s wall.
- Epochs: 362 / 189 / 188 / 188 / 186 s. Cold/warm speedup 1.93x.
- `peer_lookup_query_count = 0` across all 4 servers (correct, single-job mode).
- `sidecar_writes = 0` (correct, sidecars only fire when cross-job=1).
- **Shape-level confirmation of the zero-regression-vs-IPDPS-single-job claim.** Bit-identical comparison deferred.
- Result + summary at `benchmarks/results/single_job_baseline/`. Committed.

**In progress:** SLURM 221612 (c70) + 221613 (c71) — two-job concurrent cross-job experiment. Both jobs share `FitCache_CLUSTER_REGISTRY_DIR=/mnt/beegfs/ghu4/fitcachepp_registry_two_job_concurrent/<run-tag>/`. Expected wall: ~19m each in parallel; ~19m total.

**Heartbeat:** Monitor task `bcfafdkil` (30-min interval) running.

**Next steps after the concurrent experiment finishes**
- Grep cross-job hit counts from both jobs' server logs; quantify the cross-job-sharing-reduces-aggregate-IO claim at the 4-server-per-node × 2-job scale.
- Run the two-job sequential variant (Job B with `--dependency=afterok`) if time permits.
- PMem tier support + three-tier hardware evaluation pilot on c35 deferred to a future session (architectural change, ~4h).
- Bit-equivalence unit-test harness still pending.

**Push status:** local commits `54fb50d`, `8fb565e`, and the upcoming baseline-result commit are unpushed (no credentials in this environment).

### 2026-05-11 — Cross-job extension engineering work complete (four slices)

Four committed slices land the open/read peer-fanout path, persistent
sidecar metadata, refcount-respecting eviction, and the subscriber-lease
machinery. Engineering scope of the cross-job extension is complete
(~1,500 LOC over the four slices, within the original ~1,600 LOC budget).

**Commits (unpushed, local on `main`):**
- `c816420` — subscriber-lease management for cross-job eviction protection
- `21772a6` — refcount-respecting eviction + background reaper
- `25680e9` — persistent sidecar metadata for cross-job cache durability
- `2c76cc6` — open-time peer-lookup fanout for cross-job cache sharing
- `6f7585d` — client-side HRW routing for cross-job cache sharing (previously pushed)

**What landed in each slice:**

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
- Fixed a placeholder from the cluster-registry slice of work that landed earlier: `fitcache_server.cpp` was passing `addr=""` to `registry_register_server`. It now captures the real Mercury self-addr via the new `fitcache_comm_get_self_addr_string()` getter (populated as a side effect of `fitcache_comm_list_addr` in `src/fitcache_comm.cpp`). Without this, cross-job peer clients would have empty addresses in the registry and never resolve. The change is gated by `FitCache_CROSS_JOB=1` so single-job builds are unaffected.
- Added a fifth case to `tests/test_cross_job_smoke.cpp` — `test_routing_select_and_slot_addr` — covering slot stability across repeated calls, HRW spread across the live set, addr resolution, and the unknown-slot fallback that `fitcache_client_comm_lookup_addr` relies on. Required test restructuring after hitting the cached-`cross_job_enabled()` gotcha (recorded as `feedback_cross_job_enabled_is_cached.md` in memory).
- Build clean: pre-existing `wrappers.c`/`ms_read` and `test_open_close.c`/`fclose(int)` warnings remain (documented in `tpds_extension/05_implementation_notes.md`); no new warnings. CMake cache had to be cleared once because the repo was renamed from `FitCache` to `FitCachePP` and the stale `CMakeCache.txt` recorded the old source path.
- All five smoke tests pass: FNV-1a vectors, HRW balance + churn vs modulo, dataset_id, cluster registry roundtrip + heartbeat staleness + deregister, client-side HRW routing (HRW spread 3/3 servers, slot stable, addr lookup correct).
- Backward compatibility check: when `FitCache_CROSS_JOB=0` (the default; env-var contract documented in the cross-job design doc at `tpds_extension/02_design_cross_job.md`, "Configuration surface" section), `select_server_for_path` short-circuits to `modulo_select(path, g_fitcache_server_count)` so single-job routing is bit-identical to the IPDPS code.

**Next steps**
- Open-time peer lookup fanout in `fitcache_open_rpc_handler` (`src/fitcache_comm_server.cpp`): on cache miss, fan out `fitcache_peer_lookup_rpc` (the RPC stub already exists from the cluster-registry slice) to live peers from the cluster registry before falling back to PFS; on a positive response, redirect the server-side fd to read from the peer-job server. ~150 LOC. This is the change that actually achieves cache sharing across jobs.
- Sidecar metadata persistence (`<file>.meta` per cached file) + reference counting + real eviction (`unlink` on evict — currently only the metadata map is touched) + `subscribe`/`release` RPCs. ~530 LOC.
- After the durability work lands, run a 2-job smoke test on ARC, then run the bit-equivalence check (`FitCache_CROSS_JOB=0` vs the IPDPS configs) to defend the zero-regression-vs-IPDPS-single-job claim.
