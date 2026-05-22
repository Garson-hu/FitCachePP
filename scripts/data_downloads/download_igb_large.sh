#!/bin/bash
# Download IGB-large paper + author node_feat.npy from AWS Open Data.
# Real (no synthetic / no derivation) — totals ~889 GB.
#
# Idempotent: skips files already at expected size.
# Resumable: uses `curl -C -` to resume partial files.
# Robust: --retry 10 --retry-delay 30 --retry-max-time 0 (no overall cap).
#
# Designed to be launched with:
#   nohup setsid bash download_igb_large.sh < /dev/null > .../igb.log 2>&1 &

set -uo pipefail
OUTDIR=/lustre/orion/gen008/proj-shared/ghu4/data/gnn/igb_large_real
mkdir -p "$OUTDIR"

# Each entry is "URL|local_name|expected_bytes"
ITEMS=(
  "https://igb-public-awsopen.s3.us-west-2.amazonaws.com/igb_large/processed/paper/node_feat.npy|paper_node_feat.npy|409600000000"
  "https://igb-public-awsopen.s3.us-west-2.amazonaws.com/igb_large/processed/author/node_feat.npy|author_node_feat.npy|479067734016"
  "https://igb-public-awsopen.s3.us-west-2.amazonaws.com/igb_large/processed/conference/node_feat.npy|conference_node_feat.npy|18391168"
  "https://igb-public-awsopen.s3.us-west-2.amazonaws.com/igb_large/processed/journal/node_feat.npy|journal_node_feat.npy|199966848"
)

echo "[$(date)] IGB-large download driver starting; OUTDIR=$OUTDIR"
for entry in "${ITEMS[@]}"; do
  url=$(echo "$entry" | cut -d'|' -f1)
  name=$(echo "$entry" | cut -d'|' -f2)
  expected=$(echo "$entry" | cut -d'|' -f3)
  out="$OUTDIR/$name"
  if [ -f "$out" ]; then
    cur=$(stat -c %s "$out" 2>/dev/null || echo 0)
    if [ "$cur" = "$expected" ]; then
      echo "[$(date)] $name already complete ($cur bytes); skipping"
      continue
    fi
    echo "[$(date)] $name partial ($cur / $expected); resuming"
  else
    echo "[$(date)] $name new download from $url"
  fi
  # Time the download.
  t0=$(date +%s)
  curl -C - --retry 10 --retry-delay 30 --retry-max-time 0 -fL \
       --connect-timeout 30 \
       -o "$out" "$url"
  rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  final=$(stat -c %s "$out" 2>/dev/null || echo 0)
  mbps=$(awk -v b="$final" -v t="$elapsed" 'BEGIN { if (t>0) printf "%.2f", b/t/1024/1024; else print "0" }')
  echo "[$(date)] $name rc=$rc final=$final/$expected wall=${elapsed}s avg_MB/s=$mbps"
  if [ "$final" != "$expected" ]; then
    echo "[$(date)] WARN: $name size mismatch (final=$final, expected=$expected)"
  fi
done
echo "[$(date)] IGB-large driver done"

# Final inventory
echo "[$(date)] === final inventory ==="
ls -la "$OUTDIR" 2>/dev/null
TOTAL=$(du -sb "$OUTDIR" 2>/dev/null | awk '{print $1}')
echo "[$(date)] total bytes in $OUTDIR: $TOTAL"
