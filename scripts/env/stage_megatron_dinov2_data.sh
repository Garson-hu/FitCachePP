#!/bin/bash
# Stage real datasets for Megatron + DINOv2 mmap-interceptor validation.
#
# Layout (per user direction — one subdir per benchmark, no flat files):
#   /lustre/orion/gen008/proj-shared/ghu4/data/megatron/
#     tokenizer/                 (gpt2-vocab.json + gpt2-merges.txt)
#     enwik8/                    (raw text corpus + jsonl + tokenized .bin/.idx)
#     synth_slice/               (the pre-existing synthetic pair, kept for fallback)
#   /lustre/orion/gen008/proj-shared/ghu4/data/dinov2/
#     imagenet_synth/            (synthetic ImageNet-22k-style tree for the smoke)
#
# Real ImageNet-22k (1.4 TB, requires registration) is out of scope for an
# unblocking smoke; we generate a stand-in that exercises the same mmap
# pattern (DINOv2's tarball/dir scan + PIL.Image.open which goes through
# numpy.memmap on the JPEG buffers).
#
# Logs to /tmp/stage_megatron_dinov2_data.log
set -euo pipefail
exec > >(tee /tmp/stage_megatron_dinov2_data.log) 2>&1

echo "=== $(date) start ==="

export http_proxy=http://proxy.ccs.ornl.gov:3128/
export https_proxy=http://proxy.ccs.ornl.gov:3128/

DATA_ROOT=/lustre/orion/gen008/proj-shared/ghu4/data
MEGATRON_DIR=/lustre/orion/gen008/proj-shared/ghu4/benchmark/Megatron-LM
PY=/ccs/home/ghu4/envs/torch_rocm/bin/python

# ---------------------------------------------------------- Megatron / enwik8

ENWIK_DIR="$DATA_ROOT/megatron/enwik8"
mkdir -p "$ENWIK_DIR"
cd "$ENWIK_DIR"

if [ ! -s enwik8.zip ]; then
    echo "--- downloading enwik8 (~36 MB) ---"
    curl -L --proxy "$http_proxy" -o enwik8.zip \
        http://mattmahoney.net/dc/enwik8.zip
fi
if [ ! -s enwik8 ]; then
    echo "--- unzipping enwik8 (~100 MB raw text) ---"
    unzip -o enwik8.zip
    ls -la enwik8
fi

# Convert to JSONL with one document per ~10 KB chunk (Megatron's
# preprocess_data.py expects one JSON object per line with a "text" field).
if [ ! -s enwik8.jsonl ]; then
    echo "--- converting enwik8 -> jsonl ---"
    $PY <<'PY'
import json
src = "/lustre/orion/gen008/proj-shared/ghu4/data/megatron/enwik8/enwik8"
dst = "/lustre/orion/gen008/proj-shared/ghu4/data/megatron/enwik8/enwik8.jsonl"
chunk = 10_000  # bytes per "document"
with open(src, "r", encoding="utf-8", errors="replace") as f, \
     open(dst, "w", encoding="utf-8") as out:
    buf = ""
    for line in f:
        buf += line
        if len(buf) >= chunk:
            out.write(json.dumps({"text": buf}) + "\n")
            buf = ""
    if buf:
        out.write(json.dumps({"text": buf}) + "\n")
print("wrote", dst)
PY
fi
ls -la enwik8.jsonl

# Tokenize with Megatron's preprocess_data.py + GPT-2 BPE tokenizer.
if [ ! -s enwik8_text_document.bin ]; then
    echo "--- tokenizing enwik8 with Megatron preprocess_data.py ---"
    cd "$MEGATRON_DIR"
    $PY tools/preprocess_data.py \
        --input "$ENWIK_DIR/enwik8.jsonl" \
        --output-prefix "$ENWIK_DIR/enwik8" \
        --tokenizer-type GPT2BPETokenizer \
        --vocab-file "$DATA_ROOT/megatron/tokenizer/gpt2-vocab.json" \
        --merge-file "$DATA_ROOT/megatron/tokenizer/gpt2-merges.txt" \
        --workers 16 \
        --append-eod 2>&1 | tail -10
fi
cd "$ENWIK_DIR"
ls -la enwik8_text_document.bin enwik8_text_document.idx 2>&1

# ---------------------------------------------------------- DINOv2 / synthetic

DINO_DIR="$DATA_ROOT/dinov2/imagenet_synth"
mkdir -p "$DINO_DIR"

# Generate a tiny synthetic ImageNet22k stand-in: 100 classes x 100 imgs.
# The mmap interceptor target is DINOv2's PIL.Image.open path (PIL uses
# mmap on the JPEG buffer for large files; smaller files use read()).
# To force the mmap path the images need to be > ~16 KB. Use 224x224 RGB
# which is ~150 KB JPEG at quality 70.
NCLASSES=20
NPERCLASS=50
SAMPLE_DIR=$(ls -d "$DINO_DIR"/n* 2>/dev/null | head -1)
if [ -z "$SAMPLE_DIR" ]; then
    echo "--- generating synthetic imagenet stand-in (${NCLASSES} classes x ${NPERCLASS} imgs) ---"
    $PY - <<PY
import os
from PIL import Image
import numpy as np
root = "${DINO_DIR}"
ncls = ${NCLASSES}
nper = ${NPERCLASS}
for c in range(ncls):
    d = os.path.join(root, f"n{10000000+c:08d}")
    os.makedirs(d, exist_ok=True)
    for i in range(nper):
        arr = np.random.randint(0, 256, (224, 224, 3), dtype=np.uint8)
        Image.fromarray(arr).save(os.path.join(d, f"img_{i:05d}.jpg"), "JPEG", quality=70)
print(f"synthetic imagenet at {root}: {ncls} classes, {nper} per class")
PY
fi
ls "$DINO_DIR" 2>&1 | head -3
echo "  class count: $(ls "$DINO_DIR" | wc -l)"
echo "  image count: $(find "$DINO_DIR" -name '*.jpg' | wc -l)"
echo "  total size:  $(du -sh "$DINO_DIR" | cut -f1)"

echo "=== $(date) done ==="
