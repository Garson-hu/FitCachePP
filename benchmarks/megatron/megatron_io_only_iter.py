#!/usr/bin/env python3
"""
megatron_io_only_iter.py

I/O-only iteration over a Megatron-LM indexed-binary dataset.
Reads through Megatron's IndexedDataset (the same path Megatron's
training data loader uses) so the LD_PRELOAD'd FitCache client sees the
exact open/read pattern Megatron generates, without needing the rest of
the training stack (apex, fused kernels, distributed init, etc.).

This validates the FitCache "workload generalization to LLM pretraining"
claim at the I/O-shape level: every open + read + mmap that Megatron
would issue is issued here, but we skip the GPU compute. Pure I/O loop.

Usage:
    LD_PRELOAD=libfitcache_client.so python megatron_io_only_iter.py \
        --data-prefix /path/to/pile_slice_text_document_text_document \
        --num-iters 1000 \
        --seq-length 1024

For the FitCache-vs-baseline comparison, run twice:
  - with LD_PRELOAD=libfitcache_client.so
  - without LD_PRELOAD (Pure_CF baseline)
"""

import argparse
import os
import sys
import time

# Megatron is on PYTHONPATH via direct import path.
sys.path.insert(0, '/home/ghu4/hvac/benchmark/Megatron-LM')

from megatron.core.datasets import indexed_dataset


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--data-prefix', required=True,
                   help='Path prefix to .bin / .idx pair (Megatron --data-path style)')
    p.add_argument('--num-iters', type=int, default=1000,
                   help='Number of fake training steps')
    p.add_argument('--seq-length', type=int, default=1024,
                   help='Tokens per fake training sample (the .get() length)')
    p.add_argument('--batch-size', type=int, default=4,
                   help='Samples per step')
    args = p.parse_args()

    print(f"[io-only] opening dataset at {args.data_prefix}")
    t0 = time.time()
    # IndexedDataset is the format Megatron's data loader pulls from.
    # No tokenizer required (we already have tokens).
    ds = indexed_dataset.IndexedDataset(args.data_prefix)
    t1 = time.time()
    n_docs = len(ds)
    print(f"[io-only] dataset opened in {t1 - t0:.2f}s, {n_docs} documents")

    # The actual training I/O loop: sample documents, request seq-length
    # tokens. Megatron's get() under the hood does pread on the .bin file.
    import random
    random.seed(0)
    total_tokens = 0
    bytes_per_token = 2  # uint16 packed token id
    t0 = time.time()
    for step in range(args.num_iters):
        for _ in range(args.batch_size):
            doc_idx = random.randint(0, n_docs - 1)
            sample = ds.get(doc_idx, length=args.seq_length)
            total_tokens += len(sample)
        if step > 0 and step % 100 == 0:
            elapsed = time.time() - t0
            iters_per_sec = (step + 1) / elapsed
            mb_per_sec = (total_tokens * bytes_per_token) / (1024 * 1024) / elapsed
            print(f"[io-only] step={step}/{args.num_iters} "
                  f"{iters_per_sec:.1f} iters/s, {mb_per_sec:.2f} MB/s")
    elapsed = time.time() - t0
    print(f"[io-only] DONE {args.num_iters} iters in {elapsed:.2f}s "
          f"= {args.num_iters / elapsed:.2f} iters/s, "
          f"{(total_tokens * bytes_per_token) / (1024 * 1024) / elapsed:.2f} MB/s")


if __name__ == '__main__':
    main()
