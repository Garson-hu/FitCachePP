#!/usr/bin/env python3
"""
mmap COVERAGE + MULTI-EPOCH diagnostic for the FitCachePP mmap interceptor.

Goal: find the access-density (coverage) at which FitCachePP's eager-populate
(one sequential bulk transfer of the whole mmap'd region) starts to beat the
Native_mmap_PFS baseline (demand page-faulting only the touched pages from
PFS). Also a multi-epoch mode to measure cross-epoch cache reuse.

Reads the existing sharded corpus .bin files (raw uint16 tokens, 16 GiB each)
under --data-dir (shard_NNNN.bin). Each shard is mmap'd as one region. We
touch a controlled `--coverage` fraction of the region as `--n-chunks`
contiguous segments evenly spread across the shard (precise byte coverage +
spatial spread), summing each segment to force real byte reads.

Mechanism the sweep exposes:
  - FitCachePP: np.memmap() blocks while the interceptor EAGER-POPULATES the
    whole region (region_bytes) via chunked bulk transfer, regardless of
    coverage. Then the segment sums hit DRAM (fast). Over-reads at low
    coverage.
  - Native_mmap_PFS: np.memmap() is instant; the segment sums page-fault only
    the touched pages (~touched_bytes) from PFS, but as scattered random reads.

Checksum: sum of all touched bytes (uint64). FitCachePP and Native_mmap_PFS
MUST produce identical checksums for the same seed/coverage/shards — this is
the hard correctness gate. A mismatch means the read path is wrong.

Usage:
  [LD_PRELOAD=...] python llm_coverage_bench.py --data-dir <dir> \
      --num-shards 4 --coverage 0.10 --epochs 1 --n-chunks 2000
"""
import argparse, os, sys, time
import numpy as np

BYTES_PER_TOKEN = 2  # uint16


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--data-dir', required=True,
                   help='dir with shard_NNNN.bin (raw uint16) files')
    p.add_argument('--shard-glob', default='shard_{:04d}.bin')
    p.add_argument('--num-shards', type=int, default=4)
    p.add_argument('--coverage', type=float, default=0.10,
                   help='fraction of each shard touched (0,1]')
    p.add_argument('--n-chunks', type=int, default=2000,
                   help='contiguous segments per shard, spread across it')
    p.add_argument('--epochs', type=int, default=1)
    p.add_argument('--seed', type=int, default=0)
    p.add_argument('--label', default=None,
                   help='explicit side label; overrides the LD_PRELOAD heuristic')
    args = p.parse_args()

    side = args.label if args.label else (
        'FitCachePP' if os.environ.get('LD_PRELOAD') else 'Native_mmap_PFS')
    print(f"[cov-bench] side={side} num_shards={args.num_shards} "
          f"coverage={args.coverage} n_chunks={args.n_chunks} epochs={args.epochs}",
          flush=True)

    # Shard selection. Default (FITCACHE_PART_WORLD unset): every rank reads
    # [0, num_shards) -> the replicated full-corpus behaviour the warm-hit sweep
    # uses. Opt-in 1/N partition (set by the *_migrate_1x.sh launcher): rank r
    # reads the slice owned by owner=(rank+rotate)%world, i.e. a single 1/N
    # partition of the corpus. rotate>0 makes rank r read a NON-owned partition
    # (the reshuffle/Part-2 case that must migrate it peer->local).
    part_world = int(os.environ.get('FITCACHE_PART_WORLD', '0'))
    if part_world > 0:
        part_rank = int(os.environ.get('FITCACHE_PART_RANK',
                                       os.environ.get('SLURM_PROCID', '0')))
        rotate    = int(os.environ.get('FITCACHE_PART_ROTATE', '0'))
        owner = (part_rank + rotate) % part_world
        per   = max(1, args.num_shards // part_world)
        lo, hi = owner * per, owner * per + per
        shard_ids = list(range(lo, hi))
        base = int(os.environ.get('FITCACHE_SHARD_BASE', '0'))
        if base:
            shard_ids = [base + x for x in shard_ids]
        print(f"[cov-bench] partition: rank={part_rank} world={part_world} "
              f"rotate={rotate} owner={owner} shards=[{lo},{hi})", flush=True)
    else:
        shard_ids = list(range(args.num_shards))

    shard_paths = []
    for i in shard_ids:
        pth = os.path.join(args.data_dir, args.shard_glob.format(i))
        if not os.path.isfile(pth):
            print(f"[cov-bench] MISSING {pth}", flush=True); sys.exit(1)
        shard_paths.append(pth)

    # Opt-in ADAPTIVE placement (FITCACHE_ADAPTIVE=1): instead of the launcher
    # hard-coding 1x-vs-Nx, let the library decide at populate time.
    # The full corpus list + this node's ownership flags (from the partition
    # env, when one exists) go to fitcache_adaptive_decide(); the decision
    # rewrites what this rank prefetches:
    #   PARTITION_1X  -> prefetch owned slice, SINGLE_COPY   (r=0 case)
    #   REPLICATE_NX  -> prefetch the FULL corpus, UNBOUNDED (fits budget)
    #   PART_FALLBACK -> prefetch nothing (cache-on-miss handles the hot set)
    # FITCACHE_ADAPTIVE_UNPARTITIONABLE=1 simulates a workload that declares
    # no partition (the GNN case) regardless of FITCACHE_PART_WORLD.
    if os.environ.get('FITCACHE_ADAPTIVE') == '1':
        try:
            sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
            from fitcache_prefetch_shim import (adaptive_decide, prefetch,
                                                available, wait_local,
                                                PLACE_PARTITION_1X,
                                                PLACE_REPLICATE_NX,
                                                PLACE_PART_FALLBACK)
            base = int(os.environ.get('FITCACHE_SHARD_BASE', '0'))
            all_ids = [base + x for x in range(args.num_shards)]
            all_paths = [os.path.join(args.data_dir, args.shard_glob.format(i))
                         for i in all_ids]
            unpart = os.environ.get('FITCACHE_ADAPTIVE_UNPARTITIONABLE') == '1'
            owned_set = set(shard_paths)
            owned = None if (unpart or part_world <= 0) \
                else [1 if p in owned_set else 0 for p in all_paths]
            dec = adaptive_decide(all_paths, owned)
            if dec is None:
                print("[cov-bench] adaptive: API unavailable; falling back to "
                      "static prefetch of the partition slice", flush=True)
                to_prefetch, repl = shard_paths, 1
            elif dec['mode'] == PLACE_REPLICATE_NX:
                to_prefetch, repl = all_paths, dec['replication_mode']
            elif dec['mode'] == PLACE_PARTITION_1X:
                to_prefetch, repl = shard_paths, dec['replication_mode']
            else:  # PLACE_PART_FALLBACK
                to_prefetch, repl = [], dec['replication_mode']
            if dec is not None:
                mode_name = {PLACE_PARTITION_1X: 'PARTITION_1X',
                             PLACE_REPLICATE_NX: 'REPLICATE_NX',
                             PLACE_PART_FALLBACK: 'PART_FALLBACK'}[dec['mode']]
                print(f"[cov-bench] ADAPTIVE: mode={mode_name} "
                      f"dataset={dec['dataset_bytes']:,}B "
                      f"owned={dec['owned_bytes']:,}B "
                      f"budget={dec['budget_bytes']:,}B "
                      f"decide_us={dec['decide_us']:.1f} "
                      f"prefetching={len(to_prefetch)}/{len(all_paths)}", flush=True)
            n_hint = sum(1 for pth in to_prefetch if prefetch(pth, repl) == 0)
            wsec = int(os.environ.get('FITCACHE_PREFETCH_WAIT_SEC', '0'))
            landed = wait_local(to_prefetch, wsec) if (wsec > 0 and to_prefetch) else -1
            print(f"[cov-bench] adaptive prefetch: hinted={n_hint}/{len(to_prefetch)} "
                  f"available={available()} waited={wsec}s landed_local={landed}", flush=True)
            if to_prefetch and to_prefetch != shard_paths:
                shard_paths = to_prefetch  # read what we cached (Nx case)
        except Exception as e:
            print(f"[cov-bench] adaptive hook skipped: {e}", flush=True)
    # Opt-in prefetch hint (FITCACHE_PREFETCH=1): ask FitCachePP to migrate/promote
    # this rank's shards ahead of the read. No-op without LD_PRELOAD or the symbol.
    elif os.environ.get('FITCACHE_PREFETCH') == '1':
        try:
            sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
            from fitcache_prefetch_shim import prefetch, available, wait_local
            n_hint = sum(1 for pth in shard_paths if prefetch(pth) == 0)
            wsec = int(os.environ.get('FITCACHE_PREFETCH_WAIT_SEC', '0'))
            landed = wait_local(shard_paths, wsec) if wsec > 0 else -1
            print(f"[cov-bench] prefetch: hinted={n_hint}/{len(shard_paths)} "
                  f"available={available()} waited={wsec}s landed_local={landed}", flush=True)
        except Exception as e:
            print(f"[cov-bench] prefetch hook skipped: {e}", flush=True)

    global_cksum = np.uint64(0)
    epoch_walls = []

    for epoch in range(args.epochs):
        ep_touched = 0
        ep_region = 0
        ep_populate = 0.0
        ep_iter = 0.0
        t_ep0 = time.time()
        for si, path in enumerate(shard_paths):
            fsz = os.path.getsize(path)
            n_tok = fsz // BYTES_PER_TOKEN
            # --- populate (mmap construction; FitCachePP eager-fills here) ---
            t0 = time.time()
            mm = np.memmap(path, dtype=np.uint16, mode='r', shape=(n_tok,))
            # Touch first byte to be sure mapping is realized (no-op for FCP
            # which already populated; for Native this is one fault).
            _ = int(mm[0])
            t1 = time.time()
            populate_wall = t1 - t0
            # --- touch coverage fraction as n_chunks spread segments ---
            chunk_tok = max(1, int(args.coverage * n_tok / args.n_chunks))
            stride = max(chunk_tok, n_tok // args.n_chunks)
            t2 = time.time()
            shard_cksum = np.uint64(0)
            touched_tok = 0
            pos = 0
            for c in range(args.n_chunks):
                start = c * stride
                if start >= n_tok:
                    break
                end = min(start + chunk_tok, n_tok)
                seg = mm[start:end]
                shard_cksum = shard_cksum + np.uint64(seg.astype(np.uint64).sum())
                touched_tok += (end - start)
            t3 = time.time()
            iter_wall = t3 - t2
            del mm
            touched_bytes = touched_tok * BYTES_PER_TOKEN
            region_bytes = fsz
            cov = touched_bytes / region_bytes
            global_cksum = global_cksum + shard_cksum
            ep_touched += touched_bytes
            ep_region += region_bytes
            ep_populate += populate_wall
            ep_iter += iter_wall
            print(f"[cov-bench] {side} ep{epoch} shard{si}: "
                  f"populate={populate_wall:.2f}s iter={iter_wall:.2f}s "
                  f"total={populate_wall+iter_wall:.2f}s "
                  f"region_bytes={region_bytes:,} touched_bytes={touched_bytes:,} "
                  f"coverage={cov:.4f} "
                  f"populate_MB/s={region_bytes/1024/1024/max(populate_wall,1e-6):.1f} "
                  f"touch_MB/s={touched_bytes/1024/1024/max(iter_wall,1e-6):.1f} "
                  f"shard_cksum={int(shard_cksum)}", flush=True)
        t_ep1 = time.time()
        ep_wall = t_ep1 - t_ep0
        epoch_walls.append(ep_wall)
        tag = 'COLD' if epoch == 0 else 'warm'
        print(f"[cov-bench] {side} EPOCH {epoch} ({tag}): wall={ep_wall:.2f}s "
              f"populate={ep_populate:.2f}s iter={ep_iter:.2f}s "
              f"touched_bytes={ep_touched:,} region_bytes={ep_region:,} "
              f"touched_MB/s={ep_touched/1024/1024/max(ep_wall,1e-6):.2f}", flush=True)

    # Summary
    cold = epoch_walls[0] if epoch_walls else 0.0
    warm = (sum(epoch_walls[1:]) / max(len(epoch_walls) - 1, 1)) if len(epoch_walls) > 1 else 0.0
    amort = sum(epoch_walls)
    print(f"[cov-bench] {side} SUMMARY coverage={args.coverage} "
          f"cold_epoch_wall={cold:.2f}s warm_epoch_wall_mean={warm:.2f}s "
          f"amortized_wall={amort:.2f}s GLOBAL_CHECKSUM={int(global_cksum)}", flush=True)


if __name__ == '__main__':
    main()
