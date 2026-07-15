"""ctypes shim for FitCachePP's prefetch-informed migration (TPDS).

The benchmark drivers call ``prefetch(path)`` just before they ``mmap`` an
upcoming shard. The shim forwards to the C API exported by
``libfitcache_client.so``:

    extern "C" int fitcache_prefetch(const char *path, int replication_mode);

which routes a fire-and-forget hint to the shard's owning FitCachePP server so
it promotes / migrates the file ahead of the read. It is fully graceful: if the
library or symbol is absent (e.g. a Native_mmap_PFS baseline run with no
LD_PRELOAD), every call is a no-op returning -1, so the benchmark behaves
exactly as before.

The library is normally already resident because the benchmark runs under
``LD_PRELOAD=$FITPP_CLIENT_LIB``; we still dlopen it explicitly (idempotent) so
the symbol is reachable through ctypes.
"""

import ctypes
import os

# Replication modes — must match fitcache_replication_mode_t in
# src/cross_job/fitcache_persistent_meta.h.
REPL_UNBOUNDED = 0     # today's behavior: replicate-all, no cap
REPL_SINGLE_COPY = 1   # one copy cluster-wide; migrate peer->local on demand
REPL_BOUNDED_K = 2     # at most k copies

_FN = None
_RESOLVE = None
_INIT_DONE = False


def _init():
    """Resolve fitcache_prefetch (+ the resolver) once. Safe to call repeatedly."""
    global _FN, _RESOLVE, _INIT_DONE
    if _INIT_DONE:
        return
    _INIT_DONE = True
    candidates = []
    lib = os.environ.get("FITPP_CLIENT_LIB")
    if lib and os.path.isfile(lib):
        candidates.append(lib)
    candidates.append(None)  # the main program's already-loaded global symbols
    for cand in candidates:
        try:
            dll = ctypes.CDLL(cand, mode=ctypes.RTLD_GLOBAL) if cand \
                else ctypes.CDLL(None)
            fn = dll.fitcache_prefetch  # raises AttributeError if absent
            fn.argtypes = [ctypes.c_char_p, ctypes.c_int]
            fn.restype = ctypes.c_int
            _FN = fn
            # Best-effort: the warm-hit resolver lets wait_local() poll for the
            # migrated/promoted copy to land. Absent on older libs -> wait_local
            # returns -1 and callers fall back to a fixed sleep.
            try:
                rfn = dll.fitcache_resolve_cached_path
                rfn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]
                rfn.restype = ctypes.c_int
                _RESOLVE = rfn
            except AttributeError:
                _RESOLVE = None
            return
        except (OSError, AttributeError):
            continue
    _FN = None  # not available -> prefetch() becomes a no-op


def available():
    """True if the prefetch API resolved (LD_PRELOAD arm), else False."""
    _init()
    return _FN is not None


def prefetch(path, mode=REPL_SINGLE_COPY):
    """Hint that ``path`` is about to be mmap'd. Non-blocking.

    Returns the C return code (0 = hint sent, <0 = bad path / no server / API
    absent). Never raises.
    """
    _init()
    if _FN is None:
        return -1
    try:
        return int(_FN(os.fsencode(path), int(mode)))
    except Exception:
        return -1


def is_local(path):
    """True if `path` has a complete local cached copy (resolver hit), False if
    not, None if the resolver symbol is unavailable."""
    _init()
    if _RESOLVE is None:
        return None
    buf = ctypes.create_string_buffer(4096)
    try:
        return int(_RESOLVE(os.fsencode(path), buf, len(buf))) == 1
    except Exception:
        return None


def wait_local(paths, timeout_sec):
    """Block until every path is locally cached (migration/promotion landed) or
    timeout. Returns the count locally cached at the end, or -1 if the resolver
    is unavailable."""
    import time
    _init()
    if _RESOLVE is None:
        return -1
    paths = list(paths)
    deadline = time.time() + max(0, timeout_sec)
    while True:
        n = sum(1 for p in paths if is_local(p))
        if n >= len(paths) or time.time() >= deadline:
            return n
        time.sleep(0.5)


# --------------------------------------------------------------------------
# Adaptive placement (TPDS adaptive caching, 2026-07)
# --------------------------------------------------------------------------

PLACE_PARTITION_1X  = 0   # partition hint present -> 1x, SINGLE_COPY prefetch
PLACE_REPLICATE_NX  = 1   # un-partitionable + fits local budget -> Nx, prefetch all
PLACE_PART_FALLBACK = 2   # un-partitionable + capacity-blocked -> cache-on-miss only

_ADAPT = None
_ADAPT_INIT = False


class _AdaptiveDecision(ctypes.Structure):
    _fields_ = [("mode", ctypes.c_int),
                ("replication_mode", ctypes.c_int),
                ("dataset_bytes", ctypes.c_uint64),
                ("owned_bytes", ctypes.c_uint64),
                ("budget_bytes", ctypes.c_uint64),
                ("decide_us", ctypes.c_double)]


def _adapt_init():
    global _ADAPT, _ADAPT_INIT
    if _ADAPT_INIT:
        return
    _ADAPT_INIT = True
    _init()
    candidates = []
    lib = os.environ.get("FITPP_CLIENT_LIB")
    if lib and os.path.isfile(lib):
        candidates.append(lib)
    candidates.append(None)
    for cand in candidates:
        try:
            dll = ctypes.CDLL(cand, mode=ctypes.RTLD_GLOBAL) if cand \
                else ctypes.CDLL(None)
            fn = dll.fitcache_adaptive_decide
            fn.argtypes = [ctypes.POINTER(ctypes.c_char_p),
                           ctypes.POINTER(ctypes.c_int),
                           ctypes.c_int,
                           ctypes.POINTER(_AdaptiveDecision)]
            fn.restype = ctypes.c_int
            _ADAPT = fn
            return
        except (OSError, AttributeError):
            continue
    _ADAPT = None


def adaptive_decide(paths, owned=None):
    """Populate-time placement decision (fitcache_adaptive_decide).

    paths: all dataset files. owned: per-file 0/1 flags for THIS node's
    partition, or None if the workload has no partition (un-partitionable).
    Returns a dict {mode, replication_mode, dataset_bytes, owned_bytes,
    budget_bytes, decide_us} or None if the API is unavailable / errored.
    """
    _adapt_init()
    if _ADAPT is None:
        return None
    paths = [os.fsencode(p) for p in paths]
    arr = (ctypes.c_char_p * len(paths))(*paths)
    oarr = None
    if owned is not None:
        oarr = (ctypes.c_int * len(paths))(*[1 if o else 0 for o in owned])
    dec = _AdaptiveDecision()
    try:
        rc = _ADAPT(arr, oarr, len(paths), ctypes.byref(dec))
    except Exception:
        return None
    if rc != 0:
        return None
    return {"mode": dec.mode,
            "replication_mode": dec.replication_mode,
            "dataset_bytes": dec.dataset_bytes,
            "owned_bytes": dec.owned_bytes,
            "budget_bytes": dec.budget_bytes,
            "decide_us": dec.decide_us}
