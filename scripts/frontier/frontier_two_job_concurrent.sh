#!/bin/bash
# Frontier two-job concurrent cross-job smoke.
#
# Submits TWO FitCachePP jobs on TWO different compute nodes, both pointing
# at the same FitCache_CLUSTER_REGISTRY_DIR on Orion. Both jobs run
# CosmoFlow on the mini dataset with cross-job mode on. The goal is to
# observe — for the first time on Frontier with the post-2026-05-14
# peer-RPC-timeout watchdog in place:
#
#   - peer_lookup forwarded / handled > 0 (cross-job RPCs flow)
#   - peer_lookup_has_yes > 0          (real cache hits cross-job)
#   - opens_redirect_to_peer > 0        (a job actually consumed a peer's
#                                        cached file)
#   - peer_lookup_timeout >= 0          (timeout fires if a peer dies; the
#                                        2026-05-14 wrap-up's hang mode is
#                                        gone)
#
# Different FITPP_SEED so the two jobs access files in different orders.
# Without different seeds both jobs race on the same file simultaneously
# and the registered file is always "not yet" on the peer side.
#
# Usage:
#   bash scripts/frontier/frontier_two_job_concurrent.sh
#
# Outputs land under benchmarks/results/frontier/cross_job_concurrent/<TAG>/.

set -euo pipefail
cd "$(dirname "$0")/../.."

export FITPP_SITE=frontier
# Re-source the site config so $FITPP_REPO / $FITPP_PFS_REGISTRY_ROOT exist
# in this shell — the driver doesn't inherit them otherwise.
# shellcheck disable=SC1091
source benchmarks/sites/_resolve.sh

N_TRAIN="${FITPP_N_TRAIN:-1024}"
N_EPOCHS="${FITPP_N_EPOCHS:-3}"

RUN_TAG=$(date +'%Y%m%d_%H%M%S')_crossjob
ROOT_DIR="$FITPP_REPO/benchmarks/results/frontier/cross_job_concurrent/${RUN_TAG}"
REGISTRY_DIR="${FITPP_PFS_REGISTRY_ROOT}/cross_job_concurrent/${RUN_TAG}"
mkdir -p "$ROOT_DIR" "$REGISTRY_DIR"

echo "[driver] RUN_TAG=$RUN_TAG"
echo "[driver] cluster registry: $REGISTRY_DIR"
echo "[driver] n_train=$N_TRAIN  n_epochs=$N_EPOCHS"

SBATCH_BASE=(
    -p "$FITPP_SLURM_PARTITION"
    --account="$FITPP_SLURM_ACCOUNT"
    -C nvme
    -N 1
    -t 01:00:00
    --export=ALL
)

submit_job() {
    local TAG="$1" SEED="$2"
    local JOB_DIR="$ROOT_DIR/${TAG}"
    mkdir -p "$JOB_DIR"
    FITPP_N_TRAIN="$N_TRAIN" FITPP_N_EPOCHS="$N_EPOCHS" \
    FITPP_SEED="$SEED" \
    RESULTS_DIR="$JOB_DIR" \
    FitCache_CROSS_JOB=1 \
    FitCache_CLUSTER_REGISTRY_DIR="$REGISTRY_DIR" \
        sbatch --parsable "${SBATCH_BASE[@]}" \
            -J "FCP_${TAG}" \
            -o "$JOB_DIR/FitCachePP-%j.out" \
            benchmarks/cosmoflow/TPDS_FITPP.sh
}

JOB_A_ID=$(submit_job jobA 1)
JOB_B_ID=$(submit_job jobB 2)

echo "[driver] Job A: SLURM $JOB_A_ID  -> $ROOT_DIR/jobA/"
echo "[driver] Job B: SLURM $JOB_B_ID  -> $ROOT_DIR/jobB/"

cat > "$ROOT_DIR/manifest.txt" <<EOF
run_tag=$RUN_TAG
job_a=$JOB_A_ID
job_b=$JOB_B_ID
n_train=$N_TRAIN
n_epochs=$N_EPOCHS
registry=$REGISTRY_DIR
EOF

echo
echo "Watch progress with:"
echo "  squeue -u \$USER -j ${JOB_A_ID},${JOB_B_ID}"
echo
echo "Once jobs complete, look for cross_job_stats engagement:"
echo "  grep 'cross_job_stats' $ROOT_DIR/jobA/fitcache_server_log.*.0 | tail -3"
echo "  grep 'cross_job_stats' $ROOT_DIR/jobB/fitcache_server_log.*.0 | tail -3"
