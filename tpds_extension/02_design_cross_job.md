# Cluster-Scoped Coordination + Multi-Tenant Safety: Cross-Job Cache Sharing Design

**Purpose:** concrete protocol design for the new TPDS-version contributions.
**Anchored to:** the existing system as documented in [01_code_architecture.md](01_code_architecture.md).
**Constraints addressed:** the ten cross-job constraints listed in the architecture doc's "Summary of constraints the cross-job design must address" section.

The design is intentionally minimal — every mechanism here exists to address a specific constraint, not as a vehicle for cleverness. The goal is a TPDS-strength contribution that is also a tractable 3-month implementation.

---

## 0. Scope and non-goals

**In scope.** Multiple distributed DL training jobs running on the same HPC cluster (Frontier, GPUCLUSTER) over the same or overlapping read-only datasets, possibly with overlapping compute-node allocations, share cached training data through FitCache servers without code changes to the DL applications.

**Out of scope.**
- Writeable datasets / cache invalidation. FitCache stays read-only-data-focused (consistent with the IPDPS scope).
- Cross-cluster sharing. We assume a single cluster (one PFS, one network domain).
- Inter-user trust (different UIDs). For TPDS we restrict cross-job sharing to *same UID*; mention the multi-user case as future work in the discussion subsection.

---

## 1. Design principles

D1. **Decentralized.** No central metadata service. Same principle as the IPDPS paper.
D2. **Backward-compatible.** Single-job operation must be unchanged when cross-job mode is disabled. Drop-in claim must survive.
D3. **Path = approximate key, content-hash = exact key.** A file path is the cheap routing key; a dataset-content hash gates trust.
D4. **Best-effort sharing.** A failed peer-job lookup falls back to local cache or PFS. Cross-job sharing is a latency optimization, not a correctness dependency.
D5. **Lease-based lifetime.** Caches are owned by the cluster, not by a job. A job holds a *subscription* (lease) on a cached dataset; eviction happens when no live subscribers remain and pressure forces it.

---

## 2. Three-layer architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Layer 3: Cluster Cache Plane    (NEW for journal version)   │
│  ─ cluster registry: where do live FitCache servers live?    │
│  ─ peer-job lookup: does some other server already have      │
│      this dataset's file cached?                              │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│  Layer 2: Job Cache Plane              (existing, IPDPS)     │
│  ─ this job's FitCache servers, per-server tier hierarchy    │
│  ─ multi-source fetch (DRAM | NVMe | peer-job cache | PFS)   │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│  Layer 1: Local Cache Tier             (existing, IPDPS)     │
│  ─ tmpfs / PMem / NVMe under BBPATH                          │
│  ─ persistent dataset-namespaced layout                       │
│      (NEW for journal version)                                │
└──────────────────────────────────────────────────────────────┘
```

The IPDPS paper describes layers 1–2. The TPDS extension is layer 3 + the cross-cutting bits in layer 1 needed to make caches durable across job boundaries.

---

## 3. Dataset identity (addresses the path-string-cache-identity and no-dataset-namespace constraints)

A *dataset* is the identity unit for cross-job sharing. Cached files inherit their dataset's identity.

### 3.1 Dataset descriptor

```c
struct fitcache_dataset_id {
    char     name[64];           // human-readable, e.g. "cosmoUniverse-v1"
    uint64_t root_path_hash;     // FNV-1a of canonical(FitCache_DATA_DIR)
    uint64_t manifest_hash;      // hash of (sorted file paths + sizes + mtimes)
    uint64_t content_fingerprint;// optional: hash of N sampled files
    uint32_t version;            // bumped if manifest_hash changes
};
```

### 3.2 How the descriptor is built

- On client init, after `FitCache_DATA_DIR` is canonicalised, we walk the tree once and compute `manifest_hash = FNV-1a(sort(paths) || sizes || mtimes)`.
- For very large datasets (millions of files) the walk is the obvious bottleneck. Mitigations: (a) cache the descriptor in `${FitCache_DATA_DIR}/.fitcache_dataset.json` and reuse if `mtime(root)` is unchanged; (b) optional sampling of K files for a stronger fingerprint.
- The descriptor is broadcast to all FitCache servers in the job at startup (one Mercury RPC per server, payload < 100B).

### 3.3 Content fingerprint (optional, off by default)

A configurable env var `FitCache_DATASET_FINGERPRINT_SAMPLES` controls how many files are content-hashed (xxh64) into the fingerprint. Default 0 (off). Set to e.g. 16 for a stronger but still cheap check. This is the dataset's "version stamp" — if any of those K files change, fingerprint diverges, sharing is refused.

### 3.4 Sharing predicate

Two jobs may share a cached file iff:
1. `root_path_hash` matches (they're talking about the same dataset path), **and**
2. `manifest_hash` matches (the manifest hasn't drifted), **and**
3. If `content_fingerprint` is set in either, both are set and equal.

This is conservative by design. The cost of a false-share (returning stale data to a DL job) outweighs the cost of a false-non-share (one extra PFS read).

---

## 4. Cluster registry (addresses the job-scoped-discovery-file and orphaned-cache-files-on-disk constraints)

The IPDPS server discovery file `.ports.cfg.${SLURM_JOBID}` is *kept unchanged* for backward compatibility. We add a parallel cluster registry that crosses job boundaries.

### 4.1 Storage location

`${FitCache_CLUSTER_REGISTRY_DIR}/registry.v1/` on PFS (Lustre/BeeGFS), default to `${FitCache_DATA_DIR}/../.fitcache_registry/` if not set. Must be a directory all FitCache jobs can write to.

```
.fitcache_registry/
├── nodes/
│   ├── frontier01234.json      # one file per node
│   └── frontier01235.json
└── datasets/
    ├── <dataset_id_hex>.json   # which nodes hold cache for this dataset
    └── ...
```

### 4.2 Per-node entry

Written by the *first* FitCache server to start on a node, locked with `flock` (same primitive the IPDPS code already uses). Updated atomically (write-tmp-then-rename).

```json
{
  "hostname": "frontier01234",
  "node_uuid": "...",
  "servers": [
    {"rank": 0, "addr": "ofi+tcp;ofi_rxm://10.0.1.1:34567", "pid": 12345,
     "jobid": "1234567", "uid": 5678,
     "started_at": 1715465300, "heartbeat_at": 1715465700},
    {"rank": 1, "addr": "...", ...}
  ],
  "tiers": {
    "dram": {"path": "/dev/shm/fitcache", "capacity_bytes": 274877906944, "used_bytes": ...},
    "nvme": {"path": "/mnt/bb/fitcache", "capacity_bytes": 1932735283200, "used_bytes": ...}
  }
}
```

Heartbeat: each server `flock`s and rewrites `heartbeat_at` every 30s. A peer is considered live if `now - heartbeat_at < 90s`.

### 4.3 Per-dataset entry

```json
{
  "dataset_id": "...",
  "name": "cosmoUniverse-v1",
  "manifest_hash": "0x...",
  "subscribers": [
    {"jobid": "1234567", "uid": 5678, "lease_until": 1715470000},
    {"jobid": "1234568", "uid": 5678, "lease_until": 1715470000}
  ],
  "cached_on_nodes": ["frontier01234", "frontier01235"]
}
```

A new job appends itself to `subscribers` (file lock + atomic rewrite). A job removes itself on clean exit; a stale entry expires when `lease_until < now`. Lease length: 2× job walltime, renewed every 5min by the FitCache servers.

### 4.4 Why a PFS-backed registry instead of gossip / a daemon?

- **No new infrastructure.** PFS is already there, already trusted, already universally readable from compute nodes. A gossip layer would mean another listening service per node and another failure mode.
- **flock works.** The existing IPDPS code already uses `flock` for `.ports.cfg.*`. We're reusing the same idiom at cluster scope.
- **Read-mostly access.** Discovery happens at job startup and on cache miss — not in the hot read path. PFS latency (~500µs) is irrelevant when amortised against an epoch of training.
- **Clean failure mode.** If PFS is unreachable, the cluster registry is unavailable; FitCache transparently degrades to job-local mode.

The honest downside is that the registry is **eventually consistent**: a node that just came up may not be visible to a peer for one heartbeat interval. We accept this; cross-job sharing is best-effort (D4).

---

## 5. Routing under variable server-count (addresses the hash-modulo-routing constraint)

The IPDPS hash `host = hash(path) % N` doesn't survive different `N` across jobs. We replace it with **rendezvous hashing (HRW)** at cluster scope.

### 5.1 Algorithm

For a path `p`, the chosen server is:
```
server* = argmax over s ∈ live_servers
            xxh64(p || s.node_uuid || s.rank)
```

Properties:
- Same `p` → same server, regardless of which servers exist (only depends on the live set).
- Adding/removing a server changes the assignment for only `1/N` of paths (vs. `(N-1)/N` for naive modulo).
- Each client computes locally; no coordination needed.

### 5.2 Backward compatibility

When `FitCache_CROSS_JOB=0` (default in single-job mode), keep the modulo hash. When `FitCache_CROSS_JOB=1`, switch to HRW *for paths that belong to a registered dataset*. Untracked paths still use modulo (they're job-local anyway).

### 5.3 Cost

xxh64 is ~10ns per evaluation. With 100 servers in the live set, picking a server is ~1µs of CPU per file. Cached for the lifetime of the fd in `fd_redir_map`, so cost is amortised across all reads of that file.

---

## 6. Open / Read flow under cross-job mode

### 6.1 Open

```
client                              local FitCache server               peer-job server
  │  open(path)                                                              │
  ├──── consult cluster_registry ──┐                                         │
  │     for nodes hosting          │                                         │
  │     dataset_id(path)           │                                         │
  │  ◄─ candidate set S ───────────┘                                         │
  │                                                                          │
  │  hg_addr* = HRW(path, S ∪ local_servers)                                 │
  │                                                                          │
  ├─── fitcache_open_rpc(path, dataset_id) ──►                               │
  │                                  │                                       │
  │                                  ├─ check path_cache_map[path]?          │
  │                                  ├─ if MISS: query peers in S            │
  │                                  │  (one fitcache_peer_lookup_rpc        │
  │                                  │   per peer, parallel)                 │
  │                                  ├──────────────────────────────────────►│
  │                                  │   peer_lookup_in:  {path, ds_id}      │
  │                                  │   peer_lookup_out: {has, tier, addr}  │
  │                                  ├◄──────────────────────────────────────┤
  │                                  │                                       │
  │                                  ├─ if any peer has it AND ds_id matches:│
  │                                  │     adopt: bump ds subscriber count   │
  │                                  │     return server fd that *redirects* │
  │                                  │     reads to peer addr                │
  │                                  │                                       │
  │                                  ├─ else: open from PFS, enqueue for     │
  │                                  │     cache promotion as in IPDPS path  │
  │  ◄── server_fd ─────────────────┤                                        │
```

The new RPC is `fitcache_peer_lookup_rpc` — a tiny request/response that says "do you have this file?" with a yes/no/tier answer.

### 6.2 Read

Extension of `ms_read` (this also fixes the partial-multi-source-fetch-wiring constraint flagged in the architecture doc — currently only the DRAM RPC is visibly fired). Sources fired in parallel:
1. Local DRAM (if `path_cache_map` says so).
2. Local NVMe (if `path_cache_map` says so).
3. Peer-job server (if `open` returned a peer-redirect fd; the fd metadata carries the peer addr).
4. PFS (always, as a safety net — if all caches stall or fail, this wins).

First non-error response wins, others get cancelled (Mercury supports `HG_Cancel`). Same machinery as the existing `ms_read_state`, just with more `*_done` / `*_result` fields and a `tier` enum that includes `CACHE_TIER_PEER`.

### 6.3 Close

Unchanged from IPDPS. Does *not* trigger eviction or subscriber-decrement; that happens at job-shutdown time on the lease.

---

## 7. Cache lifecycle and reference counting (addresses the in-memory-only-metadata, no-reference-counting, and eviction-doesn't-unlink-on-disk constraints)

### 7.1 Per-file persistent metadata sidecar

For every cached file `${TIER_PATH}/<hh>/<hh>/<basename>`, write a sidecar `${TIER_PATH}/<hh>/<hh>/<basename>.meta`:

```c
struct fitcache_file_meta_v1 {
    uint32_t magic;             // 0xF17CACE0
    uint32_t version;           // 1
    uint64_t dataset_id_hash;   // ties cached file to a dataset
    uint64_t original_size;
    uint64_t cached_at_unix;
    uint64_t last_access_unix;
    uint32_t access_count;
    uint32_t refcount;          // # of jobs currently subscribing
    char     original_path[1024];
};
```

On server startup, scan the tier directory tree; rebuild `g_fileMetaMap` and `path_cache_map` from sidecars. This makes the cache **survive server restart and even node reboot** — addresses the in-memory-only-metadata constraint together with the orphaned-cache-files-on-disk constraint flagged in the architecture doc.

### 7.2 Refcount semantics

- `refcount` increments when a new job starts using this file (peer adoption or first use).
- `refcount` decrements when a job's lease in the dataset registry expires or is released.
- File is *evictable* only when `refcount == 0`.
- Eviction itself uses access-count + LRU within the evictable set, breaking ties by file size (prefer evicting larger files first to free more space per eviction).

### 7.3 Real eviction

Fix `cache_policy_remove_file`: in addition to updating the metadata map, `unlink` both the data file and its sidecar, and update `g_dram_used_bytes` / `g_nvme_used_bytes`. Ensure the `unlink` is atomic w.r.t. open handles (use `flock` on the sidecar; if a peer is mid-read, defer eviction to next pass).

### 7.4 Eviction trigger

Currently `cache_policy_evict_if_needed` is referenced but the call site is unclear (see the existing-system survey in `01_code_architecture.md`). We make this explicit:
- After every successful cache promotion in the data mover, check thresholds.
- Background reaper thread runs every 30s, evicts up to N files until usage < high-water-mark.
- Two thresholds per tier: `EVICT_HIGH_WATERMARK = 0.85`, `EVICT_LOW_WATERMARK = 0.70`.

---

## 8. Failure modes and degradation

| Failure | Detection | Behavior |
|---|---|---|
| Peer-job server crashes mid-read | Mercury RPC timeout | `ms_read` falls back to other sources (local cache or PFS); registry heartbeat marks server dead within 90s |
| Cluster registry unreachable | `open()` on registry file fails | `FitCache_CROSS_JOB` auto-disabled for the rest of the run; revert to IPDPS single-job behaviour |
| Stale registry entry (job died unclean) | `lease_until < now` or `heartbeat_at` stale | Reaper sweeps stale entries; eviction proceeds normally |
| Dataset fingerprint mismatch | At peer lookup time | Refuse adoption; treat as cache miss, read from PFS |
| Cached file corrupted (sidecar mismatch) | At server startup scan | Quarantine: rename to `.broken`, log, continue |
| Two servers race to promote same file | flock on sidecar during write | Loser detects existing valid sidecar, drops its work |

---

## 9. Configuration surface

New env vars (all optional; defaults preserve IPDPS behaviour):

| Var | Default | Effect |
|---|---|---|
| `FitCache_CROSS_JOB` | `0` | `1` enables cluster registry + peer lookup + HRW routing |
| `FitCache_CLUSTER_REGISTRY_DIR` | `${FitCache_DATA_DIR}/../.fitcache_registry` | Where the cluster registry lives |
| `FitCache_DATASET_NAME` | basename of `FitCache_DATA_DIR` | Human-readable dataset name |
| `FitCache_DATASET_FINGERPRINT_SAMPLES` | `0` | Sampled-content fingerprint strength |
| `FitCache_LEASE_RENEW_SEC` | `300` | Subscriber-lease renewal interval |
| `FitCache_HEARTBEAT_SEC` | `30` | Server liveness heartbeat |
| `FitCache_EVICT_HIGH_WM` | `0.85` | High watermark for eviction trigger |
| `FitCache_EVICT_LOW_WM` | `0.70` | Low watermark eviction stops at |

Single-job mode (`FitCache_CROSS_JOB=0`) reproduces IPDPS behaviour bit-for-bit. This protects the IPDPS results from any regression and makes "FitCache vs FitCache++" a cleanly controllable comparison in the evaluation.

---

## 10. New / modified RPCs

New:
```c
MERCURY_GEN_PROC(fitcache_peer_lookup_in_t,  ((hg_string_t)(path))((uint64_t)(dataset_id)))
MERCURY_GEN_PROC(fitcache_peer_lookup_out_t, ((int32_t)(has))((int32_t)(tier))((hg_string_t)(serve_addr)))

MERCURY_GEN_PROC(fitcache_subscribe_in_t,    ((uint64_t)(dataset_id))((uint32_t)(jobid))((uint64_t)(lease_until)))
MERCURY_GEN_PROC(fitcache_subscribe_out_t,   ((int32_t)(status)))

MERCURY_GEN_PROC(fitcache_release_in_t,      ((uint64_t)(dataset_id))((uint32_t)(jobid)))
MERCURY_GEN_PROC(fitcache_release_out_t,     ((int32_t)(status)))
```

Modified:
- `fitcache_open_in_t`: add `((uint64_t)(dataset_id))` so the server knows which dataset namespace the path belongs to.
- `fitcache_rpc_in_t` (read): no change to wire format; `requested_tier` is finally honored on the server side (fixes the unused-requested-tier-field constraint flagged in the architecture doc).

---

## 11. What this looks like in the paper's design subsections

**Cluster-Scoped Coordination subsection** (~3 pages)
- Cluster registry design (the "Cluster registry" subsection above) + figure showing the file layout
- Rendezvous-hashing routing under variable server count (the "Routing under variable server-count" subsection above) + a diagram contrasting modulo vs HRW under server churn
- Open/Read flow with peer adoption (the "Open / Read flow under cross-job mode" subsection above) + sequence diagram

**Multi-Tenant Safety, Lifecycle, and Eviction subsection** (~2 pages)
- Dataset identity + fingerprinting (the "Dataset identity" subsection above)
- Persistent sidecar metadata + refcount (the "Cache lifecycle and reference counting" subsection above)
- Lease-based subscriber tracking + eviction policy (the refcount-semantics and eviction-trigger subsections above)
- Failure-mode table (the "Failure modes and degradation" subsection above)

The diagrams from this doc translate directly into paper figures. Approximate paper-figure budget for the two new design subsections: 4 figures, 2 tables.

---

## 12. What this enables in the evaluation

(Forwarded to `04_experiment_plan.md` — but in brief, the design above gives us the knobs to measure:)

- **Concurrent-jobs experiment:** `FitCache_CROSS_JOB={0,1}`, two jobs on same dataset, same nodes, measure cache-hit ratio + per-batch I/O.
- **Sequential-reuse experiment:** one job finishes, the next starts; measure first-epoch I/O reduction.
- **Eviction-under-pressure experiment:** N concurrent jobs on N different datasets, fixed cache; measure thrash rate vs. our refcount/lease policy vs. naive LRU.
- **Failure-injection experiment:** SIGKILL one peer's server during cross-job read; measure recovery latency.

The evaluation plan in step 4 will pin these down with exact configurations.

---

## 13. Resolution of open questions from the architecture doc's "Open questions" section

| Question | Decision |
|---|---|
| Discovery transport | PFS-backed registry with flock, heartbeat (the "Cluster registry" subsection above) |
| Cluster-vs-job mode | Opt-in via `FitCache_CROSS_JOB`; auto-degrade to single-job on registry failure (the "Configuration surface" subsection above) |
| Dataset identity | Path-canonical-hash + manifest-hash (mandatory); content-fingerprint (optional) (the "Dataset identity" subsection above) |
| Tenant model | Same UID only for TPDS; multi-user noted as future work (the "Scope and non-goals" subsection above) |
| Cross-job eviction | Lease + refcount; evictable when refcount=0; LRU within evictable set (the "Cache lifecycle and reference counting" subsection above) |

---

## 14. Risks and what could blow up

R1. **Manifest scan is slow on huge datasets.** Mitigation: cache manifest, sample-based fingerprint, async scan that lets first-epoch reads proceed against the unverified cache.
R2. **Registry contention.** flock on PFS files at scale (1000+ jobs) could be slow. Mitigation: shard the registry by hash of jobid, write rate is naturally low (heartbeat per 30s).
R3. **Refcount drift.** A crashed job leaks its subscriber entry; lease expiration handles it but the window is up to `FitCache_LEASE_RENEW_SEC * 2`. Acceptable.
R4. **Peer-fetch latency exceeds PFS.** Possible if peer is on a busy node. Mitigation: the multi-source fetch already includes PFS as a competing source; slow peer doesn't block the read.
R5. **Hash collisions in dataset_id.** `manifest_hash` is 64-bit; birthday bound is 2^32 datasets. Cluster-wide datasets are << 10^6. Acceptable.
R6. **Backward-compat regression.** The whole system has to behave identically when `FitCache_CROSS_JOB=0`. Mitigation: keep all new code paths behind the flag; add an integration test that diffs trace logs between IPDPS code and TPDS code in single-job mode.

---

## 15. Implementation skeleton (preview for the implementation step)

Files to add:
- `src/fitcache_dataset_id.{cpp,h}` (~250 LOC)
- `src/fitcache_cluster_registry.{cpp,h}` (~500 LOC)
- `src/fitcache_persistent_meta.{cpp,h}` (~250 LOC)
- `src/fitcache_cross_job.{cpp,h}` (~300 LOC: peer lookup, HRW routing, subscriber mgmt)

Files to modify:
- `fitcache_comm.{h,cpp}` — new RPC declarations + wiring
- `fitcache_comm_server.cpp` — handle `peer_lookup`, modify `open` handler to consult peers
- `fitcache_comm_client.cpp` — issue subscribe/release RPCs at startup/shutdown
- `fitcache_client.cpp` — switch `host = ...` to HRW when `FitCache_CROSS_JOB=1`
- `fitcache_cache_policy.{h,cpp}` — refcount field, real eviction, dataset namespacing
- `fitcache_data_mover.cpp` — write sidecar after promotion, update refcount
- `fitcache_server.cpp` — register with cluster registry on startup; deregister on signal
- `fitcache_multi_source_read.{h,cpp}` — add `CACHE_TIER_PEER` source, fix the partial-multi-source-fetch-wiring constraint flagged in the architecture doc

Total ~1,800 added LOC + ~200 modified LOC. On budget per `00_PLAN.md`.

---

End of design doc. The related-work survey follows next.
