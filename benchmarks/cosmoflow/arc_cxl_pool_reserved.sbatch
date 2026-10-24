#!/bin/bash
#SBATCH -J fitpp_cxl_reserved
#SBATCH -p all
#SBATCH -N 8
#SBATCH -w c28,c0,c1,c2,c3,c54,c55,c56
#SBATCH -t 10:00:00
#
# arc_cxl_pool_reserved.sbatch
#
# Queues the CXL node and the GPU nodes for the remaining ARC CXL-series runs
# as one ordinary SLURM job, so the scheduler sets the nodes aside as other
# jobs end instead of us having to catch them idle at the same moment. It uses
# partition "all", whose PriorityTier (5) is above the per-GPU partitions (1),
# so later jobs cannot overtake it. When the job starts it launches
# arc_cxl_pool_reserved_runs.sh on the CXL node over ssh and keeps the
# allocation until that script writes its status file. By default the job also
# holds the CXL node; if the user already holds it with their own job, submit
# with only the GPU nodes (-N 8 -w ...), and ssh is adopted into that job.
# RUN_PLAN, MAX_TRIES and FOUR_NODES (see arc_cxl_pool_reserved_runs.sh) are
# passed through to the runner.
# Submit from the repo root:
#
#   SERVER_IS_CLIENT=1 sbatch -o benchmarks/results/arc_cxl_pool_series/reserved-%j.out \
#          benchmarks/cosmoflow/arc_cxl_pool_reserved.sbatch
#
# GPU nodes: the turin RTX 4060 Ti 16 GB nodes. In 2026-10 c50-c53 and c58
# became RTX 5060 Ti nodes, leaving seven (c0-c3, c54-c56; c0, c1 and c3 have
# a 2.5 Gb/s InfiniBand link, and a 2-GPU run on c3 matched the healthy-node
# runs), so the default node list needs SERVER_IS_CLIENT=1: c28's own RTX
# 4060 Ti 8 GB takes the eighth rank.

set -u
REPO="${FITPP_REPO:-/home/ghu4/hvac/FitCachePP}"
SERVER_NODE="${SERVER_NODE:-c28}"
OUT="$REPO/benchmarks/results/arc_cxl_pool_series"
STATUS="$OUT/reserved_${SLURM_JOB_ID}.status"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new"
# Clients are the allocation minus the server node, unless SERVER_IS_CLIENT=1
# (the server node's own GPU then takes one rank, e.g. c28's RTX 4060 Ti 8 GB
# once ARC had only seven turin RTX 4060 Ti nodes left).
if [ "${SERVER_IS_CLIENT:-0}" = "1" ]; then
    NODES=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | tr '\n' ' ')
else
    NODES=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | grep -vx "$SERVER_NODE" | tr '\n' ' ')
fi
rm -f "$STATUS"
echo "[$(date '+%F %T')] job $SLURM_JOB_ID on $NODES; starting the runs on $SERVER_NODE"

$SSH "$SERVER_NODE" "cd $REPO && FITPP_SITE=arc FITPP_REPO=$REPO DRY_RUN=${DRY_RUN:-0} RUN_PLAN='${RUN_PLAN:-}' \
    HOLD_JOB_ID=$SLURM_JOB_ID MAX_TRIES=${MAX_TRIES:-2} FOUR_NODES='${FOUR_NODES:-}' \
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
