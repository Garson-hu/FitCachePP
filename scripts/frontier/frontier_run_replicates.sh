#!/bin/bash
# Submit N independent replicates of the FitCachePP vs Pure_CF CosmoFlow
# comparison on Frontier, single-GPU. Used for variance characterization
# after the headline (single-run) result lands.
#
# Each replicate gets its own SLURM job (so it picks a fresh node and the
# /mnt/bb/$USER NVMe is a fresh mount; no warm-cache leakage between runs).
# All 2N jobs are submitted in parallel — Frontier's batch queue typically
# starts each within a minute or two.
#
# Usage:
#   bash scripts/frontier/frontier_run_replicates.sh [N_RUNS] [N_TRAIN] [N_EPOCHS]
#
# Defaults: 3 runs, n_train=1024 (mini), 3 epochs. For the headline averaged
# comparison, invoke with `3 61440 3`.
#
# Outputs land under benchmarks/results/frontier/replicates_<RUN_TAG>/ ; the
# matching parse_epoch_walltime.py script (this dir) reads that tree and
# prints a mean ± stdev table.

set -euo pipefail
cd "$(dirname "$0")/../.."

N_RUNS="${1:-3}"
N_TRAIN="${2:-1024}"
N_EPOCHS="${3:-3}"

export FITPP_SITE=frontier
export FITPP_N_TRAIN
export FITPP_N_EPOCHS

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_replicates
ROOT_DIR=benchmarks/results/frontier/replicates_${RUN_TAG}
mkdir -p "$ROOT_DIR"

SBATCH_BASE=(
    -p batch
    --account=gen008
    -C nvme
    -N 1
    -t 04:00:00
    --export=ALL
)

JOBIDS=()
for i in $(seq 1 "$N_RUNS"); do
    FITCACHEPP_DIR="$ROOT_DIR/FitCachePP_run${i}"
    PURE_CF_DIR="$ROOT_DIR/Pure_CF_run${i}"
    mkdir -p "$FITCACHEPP_DIR" "$PURE_CF_DIR"

    # FitCachePP replicate
    JOB_FITCACHEPP=$(FITPP_N_TRAIN="$N_TRAIN" FITPP_N_EPOCHS="$N_EPOCHS" \
              RESULTS_DIR="$PWD/$FITCACHEPP_DIR" \
        sbatch --parsable "${SBATCH_BASE[@]}" \
            -J "FitCachePP_rep${i}" \
            -o "$FITCACHEPP_DIR/FitCachePP-%j.out" \
            benchmarks/cosmoflow/TPDS_FITPP.sh)
    JOBIDS+=("$JOB_FITCACHEPP")

    # Pure_CF replicate
    JOB_PURE_CF=$(FITPP_N_TRAIN="$N_TRAIN" FITPP_N_EPOCHS="$N_EPOCHS" \
              FITPP_PURE_CF=1 \
              RESULTS_DIR="$PWD/$PURE_CF_DIR" \
        sbatch --parsable "${SBATCH_BASE[@]}" \
            -J "Pure_CF_rep${i}" \
            -o "$PURE_CF_DIR/Pure_CF-%j.out" \
            benchmarks/cosmoflow/TPDS_FITPP.sh)
    JOBIDS+=("$JOB_PURE_CF")

    echo "replicate $i submitted: FitCachePP=$JOB_FITCACHEPP  Pure_CF=$JOB_PURE_CF"
done

# Persist the job-id list + run config alongside the outputs so the parser
# can match jobs to their FitCachePP/Pure_CF dirs even if reorganized later.
cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
n_runs=$N_RUNS
n_train=$N_TRAIN
n_epochs=$N_EPOCHS
jobids=${JOBIDS[*]}
EOF

echo
echo "Run-tag:     $RUN_TAG"
echo "Results dir: $ROOT_DIR"
echo "Submitted:   ${#JOBIDS[@]} jobs (${N_RUNS} replicate-pairs)"
echo
echo "Wait for jobs to complete, then parse with:"
echo "  python scripts/frontier/parse_epoch_walltime.py $ROOT_DIR"
