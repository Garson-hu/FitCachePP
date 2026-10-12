#!/bin/bash
#SBATCH -J fitpp_cxl_reserved
#SBATCH -p rtx4060ti16g
#SBATCH -N 8
#SBATCH -w c2,c50,c51,c52,c53,c55,c56,c58
#SBATCH -t 10:00:00
#
# arc_cxl_pool_reserved.sbatch
#
# Queues the GPU nodes for the remaining ARC CXL-series runs as an ordinary
# SLURM job, so the scheduler sets the nodes aside as other jobs end instead of
# us having to catch eight of them idle at the same moment. When the job starts
# it launches arc_cxl_pool_reserved_runs.sh on the CXL node over ssh (the
# user's own job there must be running) and keeps the allocation until that
# script writes its status file. Submit from the repo root:
#
#   sbatch -o benchmarks/results/arc_cxl_pool_series/reserved-%j.out \
#          benchmarks/cosmoflow/arc_cxl_pool_reserved.sbatch
#
# The eight nodes are the turin nodes with a healthy InfiniBand link (c0, c1
# and c3 run at 2.5 Gb/s; c54 has a broken GPU driver).

set -u
REPO="${FITPP_REPO:-/home/ghu4/hvac/FitCachePP}"
SERVER_NODE="${SERVER_NODE:-c28}"
OUT="$REPO/benchmarks/results/arc_cxl_pool_series"
STATUS="$OUT/reserved_${SLURM_JOB_ID}.status"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new"
NODES=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | tr '\n' ' ')
rm -f "$STATUS"
echo "[$(date '+%F %T')] job $SLURM_JOB_ID on $NODES; starting the runs on $SERVER_NODE"

$SSH "$SERVER_NODE" "cd $REPO && FITPP_SITE=arc FITPP_REPO=$REPO DRY_RUN=${DRY_RUN:-0} \
    nohup setsid benchmarks/cosmoflow/arc_cxl_pool_reserved_runs.sh $STATUS $NODES \
    > $OUT/reserved_${SLURM_JOB_ID}.log 2>&1 < /dev/null &" < /dev/null \
    || { echo "cannot reach $SERVER_NODE (no running job of yours there?)"; exit 1; }

# Hold the nodes until the runner reports. If it disappears without a status
# (its job on the server node ended, or the node rebooted), give them back.
while [ ! -s "$STATUS" ]; do
    sleep 120
    if ! $SSH "$SERVER_NODE" "pgrep -f 'arc_cxl_pool_reserved_run[s].sh' > /dev/null" < /dev/null; then
        sleep 30
        [ -s "$STATUS" ] || { echo "[$(date '+%F %T')] runner gone without a status; releasing the nodes"; exit 1; }
    fi
done
echo "[$(date '+%F %T')] runner status: $(cat "$STATUS")"
