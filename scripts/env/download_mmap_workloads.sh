#!/bin/bash
# Background dataset stage-in for mmap-based workloads (Megatron + DINOv2).
# Logs to /tmp/download_mmap_workloads.log.
#
# Stages onto Orion proj-shared so the compute nodes can mount it via Lustre.
# All downloads go through OLCF's HTTPS proxy.
set -euo pipefail
exec > >(tee /tmp/download_mmap_workloads.log) 2>&1

echo "=== $(date) start ==="

export http_proxy=http://proxy.ccs.ornl.gov:3128/
export https_proxy=http://proxy.ccs.ornl.gov:3128/

BENCH_ROOT=/lustre/orion/gen008/proj-shared/ghu4/benchmark
DATA_ROOT=/lustre/orion/gen008/proj-shared/ghu4/data

# ------------------------------------------------------------------ Megatron
# The Megatron-DeepSpeed-ORNL clone on disk is incomplete (no megatron/data/
# source files). Clone canonical Megatron-LM alongside; its IndexedDataset
# uses numpy.memmap and is the de-facto reference implementation that the
# mmap-limitation analysis in benchmarks/results/arc/workload_generalization/
# was written against.
if [ ! -d "$BENCH_ROOT/Megatron-LM" ]; then
    echo "--- cloning Megatron-LM ---"
    cd "$BENCH_ROOT"
    git clone --depth 1 https://github.com/NVIDIA/Megatron-LM.git
fi
echo "Megatron-LM head: $(cd "$BENCH_ROOT/Megatron-LM" && git rev-parse --short HEAD)"

# GPT-2 tokenizer (tiny, ~5 MB total).
TOK_DIR="$DATA_ROOT/megatron_assets"
mkdir -p "$TOK_DIR"
if [ ! -s "$TOK_DIR/gpt2-vocab.json" ]; then
    echo "--- downloading GPT-2 vocab + merges ---"
    curl -L --proxy "$http_proxy" -o "$TOK_DIR/gpt2-vocab.json" \
        https://s3.amazonaws.com/models.huggingface.co/bert/gpt2-vocab.json
    curl -L --proxy "$http_proxy" -o "$TOK_DIR/gpt2-merges.txt" \
        https://s3.amazonaws.com/models.huggingface.co/bert/gpt2-merges.txt
fi
ls -la "$TOK_DIR"

# A tiny pretokenized .bin/.idx pair, useful for the mmap-interceptor smoke
# test even before a real corpus lands. Generated synthetically — values
# don't matter, only the memmap access pattern.
SLICE_DIR="$DATA_ROOT/megatron_synth_slice"
mkdir -p "$SLICE_DIR"
if [ ! -s "$SLICE_DIR/synth_text_document.bin" ]; then
    echo "--- generating synthetic .bin/.idx pair (100 MiB) ---"
    python3 - <<'PY'
import os, struct
import numpy as np
out = "/lustre/orion/gen008/proj-shared/ghu4/data/megatron_synth_slice/synth_text_document"
N = 100 * 1024 * 1024 // 2   # 100 MiB of uint16 tokens
toks = np.random.randint(0, 50257, size=N, dtype=np.uint16)
toks.tofile(out + ".bin")
# Minimal .idx — Megatron's MMapIndexedDataset header (version 1) is:
#   magic b"MMIDIDX\x00\x00" + version uint64=1 + dtype uint8 + len(sizes) uint64
#   + len(doc_idx) uint64 + sizes int32[] + pointers int64[] + doc_idx int64[]
# We pretend one document of length N tokens.
doc_len = N
sizes = np.array([doc_len], dtype=np.int32)
pointers = np.array([0], dtype=np.int64)
doc_idx = np.array([0, 1], dtype=np.int64)
with open(out + ".idx", "wb") as f:
    f.write(b"MMIDIDX\x00\x00")
    f.write(struct.pack("<Q", 1))     # version
    f.write(struct.pack("<B", 8))     # dtype code 8 = uint16
    f.write(struct.pack("<Q", len(sizes)))
    f.write(struct.pack("<Q", len(doc_idx)))
    f.write(sizes.tobytes())
    f.write(pointers.tobytes())
    f.write(doc_idx.tobytes())
print("wrote", out + ".bin", "(%.1f MB)" % (os.path.getsize(out + ".bin") / 1e6))
print("wrote", out + ".idx")
PY
fi
ls -la "$SLICE_DIR"

# ------------------------------------------------------------------ DINOv2
# Source.
if [ ! -d "$BENCH_ROOT/dinov2" ]; then
    echo "--- cloning DINOv2 ---"
    cd "$BENCH_ROOT"
    git clone --depth 1 https://github.com/facebookresearch/dinov2.git
fi
echo "DINOv2 head: $(cd "$BENCH_ROOT/dinov2" && git rev-parse --short HEAD)"

# Real ImageNet-22k is 1.4 TB and requires registration. For the mmap-
# interceptor smoke we don't need that — we need an mmap'd tarball-style
# access pattern. Generate a synthetic image-22k stand-in: a few class
# subdirs of tiny JPEGs.
DINOV2_STAND_IN="$DATA_ROOT/dinov2_imagenet_synth"
if [ ! -d "$DINOV2_STAND_IN" ]; then
    echo "--- generating synthetic imagenet stand-in (4 classes × 100 imgs) ---"
    python3 - <<'PY'
import os
try:
    from PIL import Image
except ImportError:
    print("PIL not available — skipping image generation; download_mmap_workloads will be re-run after PyTorch env is built")
    raise SystemExit(0)
import numpy as np
root = "/lustre/orion/gen008/proj-shared/ghu4/data/dinov2_imagenet_synth"
os.makedirs(root, exist_ok=True)
for cls in range(4):
    d = os.path.join(root, f"n{10000000+cls:08d}")
    os.makedirs(d, exist_ok=True)
    for i in range(100):
        arr = np.random.randint(0, 256, (32, 32, 3), dtype=np.uint8)
        Image.fromarray(arr).save(os.path.join(d, f"img_{i:05d}.jpg"), "JPEG", quality=70)
print("synthetic imagenet at", root)
PY
fi
ls "$DINOV2_STAND_IN" 2>&1 | head -5

echo "=== $(date) done ==="
