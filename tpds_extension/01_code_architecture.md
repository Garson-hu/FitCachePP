# FitCache Code Architecture (as of 2026-05-11)

Source of truth for the cross-job extension design. Captures what's currently there and — critically — **what hard-codes single-job assumptions** that the TPDS extension has to redesign.

Reading covered: all files in `src/` totaling ~3,800 LOC. Headers + most `.cpp` files read end-to-end; `fitcache_comm_client.cpp` (781 LOC) read in part — sync-context design and address cache understood.

---

## 1. Component map

```
┌─────────────────────────────────────────────────────────────┐
│  DL App (TF / PyTorch / arbitrary POSIX reader)             │
└──────────────────────────┬──────────────────────────────────┘
                           │  open/read/pread/lseek/close
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  wrappers.c   (LD_PRELOAD)                                  │
│  ─ intercepts POSIX calls, dispatches to fitcache_*         │
└──────────────────────────┬──────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  fitcache_client.cpp                                        │
│   ─ fitcache_track_file(): is path under FitCache_DATA_DIR? │
│   ─ fd_map: int fd → canonical path                         │
│   ─ fd_redir_map: local fd → remote fd                      │
│   ─ host = hash(path) % FitCache_SERVER_COUNT               │
└──────────────────────────┬──────────────────────────────────┘
                           │  Mercury RPC over ofi+tcp;ofi_rxm
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  fitcache_server (one process per server slot)              │
│   ─ Mercury HG_Init listening; address written to           │
│       ./.ports.cfg.${SLURM_JOBID}   ◄── single-job!         │
│   ─ data_mover thread: dequeues files to copy from PFS      │
│   ─ path_cache_map: original PFS path → cached path         │
│   ─ open RPC: open cached file if present, else PFS;        │
│      on close, enqueue to data_mover for promotion          │
│   ─ read RPC: pread(cached_fd, ...) + Mercury bulk push     │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. RPC surface

Defined in `fitcache_comm.h`. Mercury auto-generates input/output structs.

| RPC | Input | Output | Purpose |
|---|---|---|---|
| `fitcache_open_rpc` | `path: string` | `ret_status: int32` (server fd) | Open file on server side; consult `path_cache_map`; fall back to PFS |
| `fitcache_base_rpc` (read) | `input_val, bulk_handle, accessfd, offset, requested_tier` | `ret: int64` (bytes read) | pread + Mercury bulk push |
| `fitcache_seek_rpc` | `fd, offset, whence` | `ret: int64` | lseek64 on server fd |
| `fitcache_close_rpc` | `fd: int32` | (no response) | Close server fd; **enqueue path for cache promotion if not yet cached** |
| `fitcache_trigger_srv_print_stats_rpc` | dummy | status | Telemetry trigger |

The `requested_tier` field on the read RPC is **declared but not used** in `fitcache_rpc_handler` (server falls through to whatever fd was opened). Tier selection actually happens at open time via `path_cache_map` redirection. The multi-tier "fetch" is therefore really **multi-server** parallel reads (DRAM-rank set vs NVME-rank set in `g_pm_ranks` / `g_ssd_ranks`), not multi-tier within a single server.

---

## 3. Server discovery & routing — **biggest blocker for cross-job sharing**

### Discovery file is job-scoped
`fitcache_comm.cpp:121-167` — `fitcache_comm_list_addr()`:

```c
char *jobid =  getenv("SLURM_JOBID");
sprintf(filename, "./.ports.cfg.%s", jobid);
FILE *na_config = fopen(filename, "a+");          // flock-protected append
fprintf(na_config, "%d %s\n", fitcache_server_rank, self_addr_string);
```

Each FitCache server process appends `<rank> <mercury_addr>` to a per-job file in CWD. Clients in the same job read it to learn the address book.

**Consequence:** Job A and Job B each write to a different `.ports.cfg.${JOBID}` file. There is no mechanism today for a client in Job B to discover servers from Job A. **This is the first thing that has to change for cross-job sharing.**

### Routing is hash-modulo
`fitcache_client.cpp:139` and elsewhere:

```c
uint32_t host = std::hash<std::string>{}(fd_map[fd]) % g_fitcache_server_count;
```

Path → consistent-modulo bucket → server rank. `g_fitcache_server_count` is set per-process from env var `FitCache_SERVER_COUNT`.

**Consequence:** If Job A runs with 4 servers/node × 8 nodes = 32 servers, and Job B runs with 2 servers/node × 8 nodes = 16 servers, the same path will map to a different server in each job → no sharing even if discovery were fixed. **Cross-job design needs a routing scheme that survives different server-set memberships** (rendezvous hashing, CRUSH-style, or a fixed cluster-wide partition).

---

## 4. Cache state & lifecycle

### Per-file metadata (server-side, in-memory)
`fitcache_cache_policy.cpp` + `fitcache_cache_policy.h:46-53`:

```c
typedef struct file_meta {
    std::string   path;          // original PFS path
    cache_tier_t  current_tier;  // DRAM / NVME / PFS / UNKNOWN
    uint64_t      size;
    uint64_t      access_count;
    bool          is_open;
} file_meta_t;
```

`g_fileMetaMap : map<string, file_meta_t>` lives in process memory. **No persistence; if the server dies, the metadata is gone (cached files on disk would be orphaned).**

### Promotion path (PFS → DRAM/NVMe)
1. Open RPC: server opens file from PFS or from `path_cache_map[redir_path]` if already cached.
2. Read RPC: server `pread` from open fd, bulk-pushes to client.
3. **Close RPC** (`fitcache_comm_server.cpp:137-144`): if path not in `path_cache_map`, enqueue onto `data_queue`; signal `data_cond`.
4. Data mover (`fitcache_data_mover.cpp`) picks up:
   - Compute `hash(path)` → `subdir = hash[8:16]/hash[0:8]` (the two-level hash bin documented in the IPDPS paper's directory-layout subsection).
   - `fs::copy(original_path, cache_dir/subdir/filename)`.
   - Update `path_cache_map[original] = cached`, bump `g_dram_used_bytes` / `g_nvme_used_bytes`.

**No reference counting, no dataset identity, no eviction trigger from the data mover.** Eviction is `cache_policy_evict_if_needed()` (called from where? — grep needed; not visibly invoked in the read paths I saw). Eviction picks lowest-access-count closed DRAM file, then just calls `cache_policy_remove_file` which only updates the metadata map — **it does not remove the file on disk** as far as I can see in `fitcache_cache_policy.cpp:269-292`.

### Cache directory layout
- `BBPATH` env var = node-local fast storage root.
- `FitCache_DRAM_PATH` and `FitCache_NVME_PATH` distinct paths.
- Cached files land at `${TIER_PATH}/<hh>/<hh>/<basename>`.
- Per-job cache dirs aren't enforced; if two jobs use the same `BBPATH`, they could in principle coexist in the same tree — but with no dataset identity check, that's risky.

---

## 5. Multi-tier (multi-server) fetch — `fitcache_multi_source_read.cpp`

`ms_read(fd, buf, count, offset)`:
- Allocates `ms_read_state` with mutex/cond.
- Issues **one** read RPC tagged `requested_tier = CACHE_TIER_DRAM` to host = `hash(path) % N`.
- Currently the comment in the file (line 71) and the code only fire `dram_state` — there is a `nvme_state` allocated but no second RPC issuance visible in the snippet. Worth a closer read; this may be partially-implemented or rely on a different code path.
- `ms_read_cb` updates `pm_done` / `ssd_done`; first non-negative result wins, `ms->completed = true`, signal cond.

So the "fastest responder" architecture exists but as currently coded only competes the DRAM-tier RPC against (potentially) an NVMe-tier RPC sent to a different rank set (`g_pm_ranks` / `g_ssd_ranks`) — the design is there but the wiring is partial.

**For TPDS:** this gives us a clean place to plug in a third source (a *peer-job server* that already cached the file) without rewriting the whole fetch path — just add a third `requested_tier` candidate.

---

## 6. Per-file synchronization — `fitcache_comm_client.cpp:25-207`

A relatively new, well-designed mechanism:
- `fitcache_file_sync_context`: per-file mutex/cond/refcount/result.
- `file_sync_map: unordered_map<string, sync_ctx*>` with double-checked locking.
- 256-shard FD state map (`fd_state_shards`) using rwlocks — avoids global FD lock contention.
- `fitcache_wait_fd_ready(fd)`: poll-with-sleep loop, max 1000ms.

This is solid groundwork. The same per-file refcounting machinery can be repurposed for cross-job cache reference counting (see `02_design_cross_job.md`).

---

## 7. Tests
`tests/`:
- `basic_test.c` — minimal open/read/close
- `test_open_close.c` — same, basic POSIX exercise
- `my_ldpreload.cpp` — manual harness

There is **no integration test for multi-server, cache hit/miss correctness, eviction, or scale**. Adding a small integration suite (even just multi-server localhost) before we change anything for cross-job sharing is a worthwhile pre-step — it'll give us confidence we haven't regressed the IPDPS results when we extend the system.

---

## 8. Summary of constraints the cross-job design must address

These are referenced by name (not by number) elsewhere in the planning docs and code. Use the descriptive name when citing.

| Constraint | Where | Implication for the cluster-scoped coordination protocol |
|---|---|---|
| **Job-scoped server discovery file** — `.ports.cfg.${SLURM_JOBID}` | `fitcache_comm.cpp:131` | Need cluster-scoped discovery (shared file? gossip? per-node registry?) |
| **Hash-modulo routing tied to per-job server count** — `hash(path) % N`, N = per-job count | `fitcache_client.cpp:139`, etc. | Must use rendezvous hashing or fixed cluster partition so the same path maps to the same server across jobs with different N |
| **Path-string cache identity** — no dataset fingerprint | `path_cache_map` keys | Need dataset-hash verification before trusting another job's cached copy |
| **In-memory-only cache metadata** — lost on server death | `g_fileMetaMap` | Need persistence (sidecar metadata file per cached file, or rebuild-on-startup scan) for cross-job durability |
| **No reference counting on cached files** | absent | Add refcount; bump on cross-job adoption, decrement on job exit; evict only when zero |
| **Eviction does not unlink on disk** — `cache_policy_evict_if_needed()` only updates the metadata map | `fitcache_cache_policy.cpp:289` | Fix as part of eviction work; needed for multi-tenant pressure to actually reclaim space |
| **`requested_tier` read-RPC field is unused** | `fitcache_comm_server.cpp:84` | Easy win: actually wire it up so a single server can serve from a specific tier — useful for the three-tier hardware evaluation too |
| **Multi-source fetch wiring is partial** — only DRAM RPC visibly fired in `ms_read` | `fitcache_multi_source_read.cpp:71-73` | Verify and fix before extending to peer-job source |
| **No dataset namespace / isolation** | absent | Add `dataset_id` (hash of dataset root path + content fingerprint) as namespace key |
| **Server crash leaves orphaned cache files on disk** | implicit | Need cleanup/recovery on server start; enables persistent cross-job cache |

---

## 9. Suggested code organization for the extension

New files:
- `src/fitcache_dataset_id.{cpp,h}` — dataset fingerprinting + identity
- `src/fitcache_cluster_registry.{cpp,h}` — cluster-scoped server discovery (replaces the `.ports.cfg.*` mechanism for cross-job mode; keep the old one as a fallback)
- `src/fitcache_cross_job.{cpp,h}` — peer-job discovery, cache adoption, refcounting
- `src/fitcache_persistent_meta.{cpp,h}` — sidecar metadata so the cache survives server restart

Files to modify:
- `fitcache_comm.cpp` — discovery
- `fitcache_client.cpp` — routing (hash strategy)
- `fitcache_comm_server.cpp` — open RPC consults peer-job caches; close RPC bumps refcount
- `fitcache_cache_policy.{cpp,h}` — refcount, dataset-aware eviction, actually-delete on evict
- `fitcache_multi_source_read.cpp` — add peer-job server as a third fetch source

Estimated added LOC: ~1,600–1,800 (consistent with the budget in `00_PLAN.md`).

---

## 10. Open questions (to resolve in the cross-job design doc)

1. **Discovery transport.** Shared file on PFS (`/path/to/cluster_registry`)? Lightweight gossip? Or rely on a per-node daemon outside the job?
2. **Cluster-vs-job mode.** Should cross-job sharing be opt-in (env var) or default? What's the failure mode when a peer-job server disappears mid-read?
3. **Dataset identity.** Cheap approach (hash of dataset root path + manifest file) vs strong approach (Merkle tree over file contents). For read-only DL datasets, manifest-hash should suffice — but we need to think about whether the same dataset path can mean different content across jobs (e.g., user updates the dataset).
4. **Tenant model.** Can jobs from different users share cache, or only same-user? Frontier security policy may dictate this.
5. **Eviction across jobs.** "Evict caches with no active subscriber first" is the obvious policy — but how do we detect "no active subscriber" without a centralized registry? Lease-based: each job renews leases; cache is evictable when all leases expire.

These five questions drive the design doc. Stopping the architecture pass here and proceeding to step 2.
