#!/usr/bin/env python3
"""Parse per-epoch wall-clock from FitCachePP / Pure_CF replicate runs.

Reads a results directory containing FitCachePP_runN/ and Pure_CF_runN/ subdirs
(as produced by frontier_run_replicates.sh) and prints a Markdown summary
table with mean and stdev per epoch index across replicates.

The wall-clock-per-epoch line emitted by cosmoflow looks like:

    256/256 - 96s - loss: 0.3299 - ... - time: 96.3196 - 96s/epoch - 377ms/step

We pull the `time: <float>` field (the actual wall-clock seconds; the leading
`<N>s -` is just rounded). The Markdown output is a self-contained summary
that can be appended to the run-tag's results dir.

Usage:
    python scripts/frontier/parse_epoch_walltime.py <results_dir>
"""
from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path

# Cosmoflow's Keras progress-bar epoch line: pull the canonical `time: X.YYY`
# float (more precise than the leading `Ns -` round).
EPOCH_TIME_RE = re.compile(r"\btime:\s*([0-9.]+)")
EPOCH_HEADER_RE = re.compile(r"^Epoch (\d+)/\d+\s*$")


def parse_epoch_times(out_path: Path) -> list[float]:
    """Return per-epoch wall-clock seconds (in epoch order)."""
    epochs: list[float] = []
    current_epoch = 0
    with out_path.open() as f:
        for line in f:
            m = EPOCH_HEADER_RE.match(line)
            if m:
                current_epoch = int(m.group(1))
                continue
            if current_epoch and (m := EPOCH_TIME_RE.search(line)):
                # Take the first `time:` after the epoch header — that's the
                # train+val wall-clock for that epoch (cosmoflow emits it on
                # the progress-bar closing line).
                epochs.append(float(m.group(1)))
                current_epoch = 0  # don't re-record for the same epoch
    return epochs


def mean_stdev(xs: list[float]) -> tuple[float, float]:
    n = len(xs)
    if n == 0:
        return float("nan"), float("nan")
    mean = sum(xs) / n
    if n == 1:
        return mean, 0.0
    var = sum((x - mean) ** 2 for x in xs) / (n - 1)
    return mean, math.sqrt(var)


def collect(results_dir: Path, prefix: str) -> list[list[float]]:
    """For prefix='FitCachePP', find all FitCachePP_runN dirs and return one
    epoch-list per replicate."""
    per_replicate: list[list[float]] = []
    for run_dir in sorted(results_dir.glob(f"{prefix}_run*")):
        out_files = list(run_dir.glob("*.out"))
        if not out_files:
            sys.stderr.write(f"WARN: no .out in {run_dir}\n")
            continue
        # Each replicate has one job's .out (the matching FitCachePP-*.out
        # or Pure_CF-*.out).
        epochs = parse_epoch_times(out_files[0])
        if not epochs:
            sys.stderr.write(f"WARN: no epoch times parsed from {out_files[0]}\n")
            continue
        per_replicate.append(epochs)
    return per_replicate


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("results_dir", type=Path, help="dir containing FitCachePP_run*/ + Pure_CF_run*/")
    args = ap.parse_args()

    if not args.results_dir.is_dir():
        sys.stderr.write(f"ERROR: not a directory: {args.results_dir}\n")
        return 2

    fcp = collect(args.results_dir, "FitCachePP")
    pcf = collect(args.results_dir, "Pure_CF")

    if not fcp or not pcf:
        sys.stderr.write("ERROR: missing FitCachePP or Pure_CF replicates\n")
        return 1

    n_epochs = min(min(len(r) for r in fcp), min(len(r) for r in pcf))
    n_fcp = len(fcp)
    n_pcf = len(pcf)

    print(f"# Replicate summary — {args.results_dir.name}")
    print()
    print(f"FitCachePP replicates: {n_fcp}   Pure_CF replicates: {n_pcf}   "
          f"epochs: {n_epochs}")
    print()
    print("| Epoch | FitCachePP mean ± stdev (s) | Pure_CF mean ± stdev (s) | Δ (FCP − PCF) | FCP/PCF |")
    print("|---|---|---|---|---|")
    for e in range(n_epochs):
        fcp_e = [r[e] for r in fcp]
        pcf_e = [r[e] for r in pcf]
        fcp_mean, fcp_std = mean_stdev(fcp_e)
        pcf_mean, pcf_std = mean_stdev(pcf_e)
        delta = fcp_mean - pcf_mean
        ratio = fcp_mean / pcf_mean if pcf_mean else float("nan")
        label = "cold" if e == 0 else f"warm-{e}"
        print(f"| {e+1} ({label}) | {fcp_mean:.2f} ± {fcp_std:.2f} | "
              f"{pcf_mean:.2f} ± {pcf_std:.2f} | {delta:+.2f} s | {ratio:.3f} |")
    print()
    print("Per-replicate raw values:")
    print()
    print("- FitCachePP:")
    for i, r in enumerate(fcp, 1):
        print(f"  - run{i}: " + ", ".join(f"{x:.2f}" for x in r))
    print("- Pure_CF:")
    for i, r in enumerate(pcf, 1):
        print(f"  - run{i}: " + ", ".join(f"{x:.2f}" for x in r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
