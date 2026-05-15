#!/usr/bin/env python3
"""
evict_page_cache.py <path> [<path> ...]

Walk each path (file or directory tree) and ask the kernel to drop the
file's pages from the OS page cache via posix_fadvise(POSIX_FADV_DONTNEED).
No sudo required; the hint is per-file and uses the caller's regular
file-open permissions.

Use case for FitCache++ experiments:
    Before each "cold-cache" replicate, evict the dataset directory from
    both the GPU client node's page cache AND the storage server node's
    page cache so the cold-epoch measurement truly reflects disk/PFS
    read cost instead of being masked by Linux's free RAM holding the
    dataset.

Example:
    evict_page_cache.py /mnt/beegfs/.../cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440/

Exit code: 0 always (eviction is advisory; per-file failures are tolerated).

Reference: man posix_fadvise(2), POSIX_FADV_DONTNEED.
"""
import os
import sys


def evict_one(path: str) -> tuple[int, int]:
    """Evict a single file. Returns (bytes_advised, errors)."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return (0, 1)
    try:
        size = os.fstat(fd).st_size
        # POSIX_FADV_DONTNEED with offset=0, len=0 hints the entire file.
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        return (size, 0)
    except OSError:
        return (0, 1)
    finally:
        os.close(fd)


def evict_path(path: str) -> tuple[int, int, int]:
    """Walk path (file or dir tree). Returns (files_evicted, total_bytes, errors)."""
    files = bytes_total = errors = 0
    if os.path.isfile(path):
        b, e = evict_one(path)
        return (1 if not e else 0, b, e)
    if not os.path.isdir(path):
        return (0, 0, 1)
    for root, _, fnames in os.walk(path):
        for f in fnames:
            b, e = evict_one(os.path.join(root, f))
            if not e:
                files += 1
                bytes_total += b
            else:
                errors += 1
    return (files, bytes_total, errors)


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write(f"usage: {sys.argv[0]} <path> [<path> ...]\n")
        return 2
    total_files = total_bytes = total_errors = 0
    for p in sys.argv[1:]:
        files, b, e = evict_path(p)
        total_files += files
        total_bytes += b
        total_errors += e
        gb = b / (1024 ** 3)
        print(f"[evict] {p}: {files} files, {gb:.2f} GiB advised "
              f"({e} errors)")
    gb_total = total_bytes / (1024 ** 3)
    print(f"[evict] TOTAL: {total_files} files, {gb_total:.2f} GiB advised "
          f"({total_errors} errors)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
