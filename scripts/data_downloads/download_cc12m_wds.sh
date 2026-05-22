#!/bin/bash
# Download pixparse/cc12m-wds tar shards from HuggingFace.
# Real: 996 .tar shards, 504 GiB total (genuine CC12M images packaged as
# WebDataset).
#
# Idempotent: skips shards already at expected size (per manifest).
# Resumable: uses `curl -C -` for partial-file resume.
#
# Designed to be launched with:
#   nohup setsid bash download_cc12m_wds.sh < /dev/null > .../cc12m.log 2>&1 &

set -uo pipefail
OUTDIR=/lustre/orion/gen008/proj-shared/ghu4/data/dinov2/cc12m_wds
MANIFEST=/lustre/orion/gen008/proj-shared/ghu4/FitCachePP/scripts/data_downloads/cc12m_manifest.tsv
BASE_URL=https://huggingface.co/datasets/pixparse/cc12m-wds/resolve/main
mkdir -p "$OUTDIR"

if [ ! -f "$MANIFEST" ]; then
  echo "[$(date)] ERROR: missing manifest at $MANIFEST" >&2
  exit 1
fi

echo "[$(date)] CC12M-wds download driver starting; OUTDIR=$OUTDIR"
echo "[$(date)] manifest: $MANIFEST ($(wc -l < "$MANIFEST") shards)"

total_ok=0
total_bytes=0
t_global0=$(date +%s)

while IFS=$'\t' read -r path expected; do
  out="$OUTDIR/$path"
  if [ -f "$out" ]; then
    cur=$(stat -c %s "$out" 2>/dev/null || echo 0)
    if [ "$cur" = "$expected" ]; then
      total_ok=$((total_ok + 1))
      total_bytes=$((total_bytes + cur))
      continue
    fi
  fi
  # Need to (re)download.
  t0=$(date +%s)
  curl -C - --retry 10 --retry-delay 15 --retry-max-time 0 -fL \
       --connect-timeout 30 \
       -s -o "$out" "$BASE_URL/$path"
  rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  final=$(stat -c %s "$out" 2>/dev/null || echo 0)
  if [ "$final" = "$expected" ]; then
    total_ok=$((total_ok + 1))
    total_bytes=$((total_bytes + final))
    mbps=$(awk -v b="$final" -v t="$elapsed" 'BEGIN { if (t>0) printf "%.2f", b/t/1024/1024; else print "0" }')
    echo "[$(date)] $path OK $final bytes ${elapsed}s ${mbps} MB/s (cumulative $total_ok / 996 shards, $((total_bytes / 1024 / 1024 / 1024)) GiB)"
  else
    echo "[$(date)] $path FAIL rc=$rc final=$final expected=$expected (will retry on next pass if rerun)"
  fi
done < "$MANIFEST"

t_global1=$(date +%s)
echo "[$(date)] CC12M-wds driver done; total $total_ok/996 shards, $total_bytes bytes, wall=$((t_global1 - t_global0))s"

# Final inventory
echo "[$(date)] === final inventory ==="
TOTAL=$(du -sb "$OUTDIR" 2>/dev/null | awk '{print $1}')
COUNT=$(ls "$OUTDIR"/*.tar 2>/dev/null | wc -l)
echo "[$(date)] $COUNT shards, $TOTAL bytes ($((TOTAL / 1024 / 1024 / 1024)) GiB)"
