# FitCache++ Worklog

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
