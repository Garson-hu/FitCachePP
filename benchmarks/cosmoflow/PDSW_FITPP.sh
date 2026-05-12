#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -t 1-00:00:00
#SBATCH -J FitCachePP
#SBATCH --mail-type=END
#SBATCH --mail-user=ghu4@ncsu.edu
#SBATCH -o /home/ghu4/hvac/FitCachePP/benchmarks/results/single_job_baseline/FitCachePP-%j.out
#
# Single-job FitCache++ baseline benchmark (CosmoFlow on cosmoUniverse-mini).
# Runs FitCache++ in single-job mode (FitCache_CROSS_JOB=0). Wall-clock and
# per-batch I/O numbers should match the IPDPS PDSW_FIT.sh runs in
# logs/pdsw/ — defends the zero-regression-vs-IPDPS-single-job claim.
#
# Adapted from /home/ghu4/hvac/benchmark/cosmoflow-benchmark-master/PDSW_FIT.sh
# (the IPDPS MS_READ-based variant). Differences from PDSW_FIT.sh:
#   - Server binary: /home/ghu4/hvac/FitCachePP/build/src/fitcache_server
#     (was /mnt/beegfs/ghu4/hvac/GHU_HVAC/build/src/hvac_server)
#   - Client lib (in command_CF_FITPP.sh): libfitcache_client.so from
#     FitCache++ build (was MS_READ libhvac_client.so)
#   - Env-var prefix: FitCache_* (was HVAC_*)
#   - Cross-job mode OFF for this baseline run; the cross-job experiments
#     live in PDSW_FITPP_two_job_*.sh
#
# Server count = 4, all on the single client/server node. Matches the
# 4-servers-per-node default for non-trivial datasets.

# !!! Pick a single rtx4060ti16g node (sbatch will fill SLURM_NODELIST).
#     Override -w via sbatch CLI if you want a specific node, e.g.
#     sbatch -w c54 PDSW_FITPP.sh

# Server topology: 4 FitCache++ servers + 1 client GPU on the same node.
SERVER_NODES_DEFAULT="$(scontrol show hostnames $SLURM_JOB_NODELIST | head -1)"
SERVER_NODES="${SERVER_NODES:-$SERVER_NODES_DEFAULT}"
SERVERS_PER_NODE="4"
CLIENT_NODES="${CLIENT_NODES:-$SERVER_NODES_DEFAULT}"
GPUS_PER_NODE=1
export FitCache_SERVER_COUNT=4

# Parse to arrays
read -a SERVER_NODES_ARR  <<< "$SERVER_NODES"
read -a SERVERS_PER_NODE_ARR <<< "$SERVERS_PER_NODE"
read -a CLIENT_NODES_ARR  <<< "$CLIENT_NODES"

# Sanity
[ ${#SERVER_NODES_ARR[@]} -eq 0 ]                           && { echo "ERROR: SERVER_NODES empty"; exit 1; }
[ ${#SERVER_NODES_ARR[@]} -ne ${#SERVERS_PER_NODE_ARR[@]} ] && { echo "ERROR: SERVERS_PER_NODE size mismatch"; exit 1; }

CALC_TOTAL=0
for n in "${SERVERS_PER_NODE_ARR[@]}"; do CALC_TOTAL=$((CALC_TOTAL + n)); done
[ "$CALC_TOTAL" -ne "$FitCache_SERVER_COUNT" ] && { echo "ERROR: FitCache_SERVER_COUNT ($FitCache_SERVER_COUNT) != sum-of-SERVERS_PER_NODE ($CALC_TOTAL)"; exit 1; }

# Build Horovod host list
TOTAL_GPUS=$(( ${#CLIENT_NODES_ARR[@]} * GPUS_PER_NODE ))
HOROVOD_HOSTLIST=""
for node in "${CLIENT_NODES_ARR[@]}"; do
    HOROVOD_HOSTLIST+="${node}:${GPUS_PER_NODE},"
done
HOROVOD_HOSTLIST=${HOROVOD_HOSTLIST%,}

# Mercury / log4c env (mirrors the build env)
# INFO threshold (600) so the per-Open RPC trace + cross_job_stats periodic
# emit + data-mover-promotion lines all land in the log file. NOTICE (500)
# filters all of those — and at NOTICE with zero registry errors the file
# is never created at all, which makes the engagement self-check think
# FitCache wasn't engaged when it actually was.
export FitCache_LOG_LEVEL=600
export RDMAV_FORK_SAFE=1
export VERBS_LOG_LEVEL=4
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/rlibrary/miniconda3/envs/hvac_tf/bin:/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH

# Tier paths + capacity. NVMe only here (rtx4060ti16g nodes don't have PMem;
# the three-tier eval lives in PDSW_FITPP_three_tier.sh and runs on c35).
# Tier paths + capacities. Caller may override (e.g., cross-job runs use
# per-RUN_TAG'd dirs to avoid collisions on shared /mnt/local).
export FitCache_DRAM_PATH="${FitCache_DRAM_PATH:-/mnt/local/ghu4/fitcachepp_train_cache_dram}"
export FitCache_NVME_PATH="${FitCache_NVME_PATH:-/mnt/local/ghu4/fitcachepp_train_cache_nvme}"
export FitCache_DRAM_CAPACITY="${FitCache_DRAM_CAPACITY:-$((100 * 1024 * 1024 * 1024))}"
export FitCache_NVME_CAPACITY="${FitCache_NVME_CAPACITY:-$((500 * 1024 * 1024 * 1024))}"
# NOTE: Drop the trailing /train/ so FitCache_DATA_DIR is the canonical PARENT
# of both train/ and validation/ subdirs. The LD_PRELOAD client in
# fitcache_client.cpp:116 does a substring match between a candidate file's
# parent-path and canonical(FitCache_DATA_DIR); pointing at the parent makes
# the filter catch validation reads too, not just training reads.
# Both train.py (--data-dir) and the FitCache shim must agree on this path,
# or every read passes through to BeeGFS direct and the FitCache pathway
# stays dormant (root cause of the zero-Open-RPC cluster runs on 2026-05-11).
export FitCache_DATA_DIR="${FitCache_DATA_DIR:-/mnt/beegfs/ghu4/hvac/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440}"

export BBPATH=$FitCache_NVME_PATH

# Single-job baseline default: cross-job OFF. Servers behave exactly like
# IPDPS. Caller can override via --export=FitCache_CROSS_JOB=1 (e.g. the
# two-job concurrent driver in PDSW_FITPP_two_job_concurrent_v2.sh).
export FitCache_CROSS_JOB="${FitCache_CROSS_JOB:-0}"

# Hand off to the shared launcher PDSW_FITPP_inner.sh — same code path as the
# two-job and three-tier benchmarks. The inner script handles:
#   - cd into RESULTS_DIR so log4c files land alongside the rest of the
#     job's outputs (not the repo root)
#   - export FitCache_PORTS_CFG_DIR so server (which cd's here) and client
#     (which cd's into the training dir for configs/cosmo.yaml) agree on
#     where to find .ports.cfg.<JOBID>
#   - the FitCache-engagement self-check at the end (greps Open RPC count
#     in the server logs — fails loud if zero)
# Inherits SERVER_NODES / SERVERS_PER_NODE / CLIENT_NODES / FitCache_SERVER_COUNT
# from the variable defaults above.
# Caller can override RESULTS_DIR (e.g., for cross-job concurrent runs that
# want per-job dirs); default is the single-job baseline.
export RESULTS_DIR="${RESULTS_DIR:-/home/ghu4/hvac/FitCachePP/benchmarks/results/single_job_baseline}"
mkdir -p "$RESULTS_DIR"
exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
