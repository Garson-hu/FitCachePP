#!/bin/bash
# Download IGB-large edge index files + paper labels (needed for the
# Option 2 graph-sampler-driven feature gather benchmark).
#
# Real (no synthetic / no derivation).
# ~32 GB total (vs the ~889 GB feature side handled by download_igb_large.sh).
#
# Idempotent + resumable.

set -uo pipefail
OUTDIR=/lustre/orion/gen008/proj-shared/ghu4/data/gnn/igb_large_real
mkdir -p "$OUTDIR"

ITEMS=(
  "https://igb-public-awsopen.s3.us-west-2.amazonaws.com/igb_large/processed/paper__cites__paper/edge_index.npy|paper_cites_paper.edge_index.npy|19577141952"
  "https://igb-public-awsopen.s3.us-west-2.amazonaws.com/igb_large/processed/paper__written_by__author/edge_index.npy|paper_written_by_author.edge_index.npy|4632033840"
  "https://igb-public-awsopen.s3.us-west-2.amazonaws.com/igb_large/processed/paper__topic__fos/edge_index.npy|paper_topic_fos.edge_index.npy|7321236832"
  "https://igb-public-awsopen.s3.us-west-2.amazonaws.com/igb_large/processed/paper/node_label_19.npy|paper_node_label_19.npy|400000000"
  "https://igb-public-awsopen.s3.us-west-2.amazonaws.com/igb_large/processed/paper/node_label_2K.npy|paper_node_label_2K.npy|400000000"
)

echo "[$(date)] IGB-large edges + labels driver starting; OUTDIR=$OUTDIR"
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
    echo "[$(date)] $name new download"
  fi
  t0=$(date +%s)
  curl -C - --retry 10 --retry-delay 30 --retry-max-time 0 -fL \
       --connect-timeout 30 -s \
       -o "$out" "$url"
  rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  final=$(stat -c %s "$out" 2>/dev/null || echo 0)
  mbps=$(awk -v b="$final" -v t="$elapsed" 'BEGIN { if (t>0) printf "%.2f", b/t/1024/1024; else print "0" }')
  echo "[$(date)] $name rc=$rc final=$final/$expected wall=${elapsed}s avg_MB/s=$mbps"
done
echo "[$(date)] IGB-edges driver done"
ls -la "$OUTDIR" 2>/dev/null
