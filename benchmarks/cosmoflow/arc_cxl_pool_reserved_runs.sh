#!/bin/bash
#
# arc_cxl_pool_reserved_runs.sh <status_file> <node>...
#
# Server-node half of arc_cxl_pool_reserved.sbatch. Started over ssh on the CXL
# node (c28) once SLURM has granted the reserved GPU nodes, it runs the planned
# CXL-series runs one after another on those nodes and, when it stops, writes a
# one-line status to <status_file> (on the shared home), which is what lets the
# batch job release the nodes.
#
# Plan: the three 8-GPU runs on all eight nodes, then three more 4-GPU runs on
# FOUR_NODES (the 2026-10 runs used c2, c3, c54, c55: the IPDPS 4-GPU nodes c50
# and c51 had become RTX 5060 Ti). Runs that already have a result are skipped.
# DRY_RUN=1 only does the pre-flight checks.

set -u
STATUS="${1:?usage: arc_cxl_pool_reserved_runs.sh <status_file> <node>...}"; shift
NODES=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh"
OUT="${FITPP_RESULTS_ROOT}/arc_cxl_pool_series"
FAMFS_DIR=/mnt/famfs/dax2.0/ghu4_deeptier

log()      { echo "[$(date '+%F %T')] $*"; }
finish()   { log "$1"; echo "$1" > "$STATUS"; exit 0; }
done_run() { grep -qs 'Total epoch time' "$OUT/gpus$1_$2"/horovodrun_*.log; }

log "reserved nodes: ${NODES[*]}"

# Pre-flight. A reboot wipes the CXL memory: famfs comes back mounted but empty,
# and the user-owned project dir has to be re-created with the sudo-allowed
# famfs-mkdir wrapper (the servers re-create the pool files themselves).
grep -q ' /mnt/famfs/dax2.0 ' /proc/mounts || finish "ABORT: famfs not mounted on $(hostname -s)"
# The famfs FUSE shadow lives under /tmp, which systemd-tmpfiles empties of
# anything untouched for 10 days; reading it keeps the mount usable.
SHADOW=$(grep ' /mnt/famfs/dax2.0 ' /proc/mounts | grep -o 'shadow=[^, ]*' | cut -d= -f2)
[ -n "$SHADOW" ] && find "$SHADOW" -type f -exec cat {} + > /dev/null 2>&1
if [ ! -d "$FAMFS_DIR" ]; then
    log "famfs project dir missing (fresh mount); re-creating it"
    sudo -n /usr/local/bin/famfs-mkdir -m 0755 "$FAMFS_DIR" || finish "ABORT: cannot re-create $FAMFS_DIR"
fi
for _ in $(seq 1 30); do pgrep -x fitcache_server > /dev/null || break; sleep 60; done
pgrep -x fitcache_server > /dev/null && finish "ABORT: servers of another run are still up on $(hostname -s)"
# The comparison only holds on RTX 4060 Ti clients; ARC has been swapping GPUs
# (c50-c53 and c58 became RTX 5060 Ti in 2026-10), so check before using a node.
for n in "${NODES[@]}"; do
    gpu=$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$n" \
              'nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1' < /dev/null 2>/dev/null)
    [[ "$gpu" == *"4060 Ti"* ]] || finish "ABORT: $n has GPU '${gpu:-none}', not an RTX 4060 Ti"
done
[ "${DRY_RUN:-0}" = "1" ] && finish "DRY_RUN OK: famfs ready, nodes ${NODES[*]}"

# Nodes for 4-GPU runs: FOUR_NODES if given, else the IPDPS 4-GPU set; either
# way only if all of them are in this allocation, else its first four nodes.
read -r -a FOUR <<< "${FOUR_NODES:-c50 c51 c55 c56}"
for n in "${FOUR[@]}"; do
    printf '%s\n' "${NODES[@]}" | grep -qx "$n" || { FOUR=("${NODES[@]:0:4}"); break; }
done

# A run that fails (no "Total epoch time") is retried up to MAX_TRIES times,
# and no attempt is started that the allocation (HOLD_JOB_ID) cannot finish:
# getting these nodes again can take a week.
MAX_TRIES="${MAX_TRIES:-2}"
declare -A RUN_SECS=([1]=36000 [2]=12600 [4]=6600 [8]=4500 [16]=3000)   # one run, with headroom
secs_left() {
    local l d=0 h=0 m=0 s=0 a b c
    l=$(squeue -h -j "${HOLD_JOB_ID:-0}" -o %L 2>/dev/null)
    [ -z "$l" ] && { echo 999999; return; }
    [[ "$l" == *-* ]] && { d=${l%%-*}; l=${l#*-}; }
    IFS=: read -r a b c <<< "$l"
    if [ -n "$c" ]; then h=$a; m=$b; s=$c; elif [ -n "$b" ]; then m=$a; s=$b; else s=$a; fi
    echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# RUN_PLAN lets a caller run part of the plan, e.g. "8 rep1;8 rep2;8 rep3"
# (interactive allocations are capped at 6 h on ARC, which does not fit all six).
IFS=';' read -r -a PLAN <<< "${RUN_PLAN:-8 rep1;8 rep2;8 rep3;4 rep4;4 rep5;4 rep6}"
for run in "${PLAN[@]}"; do
    read -r g tag <<< "$run"
    done_run "$g" "$tag" && { log "gpus=$g $tag already done; skipping"; continue; }
    if [ "$g" = 8 ]; then nodes="${NODES[*]}"; else nodes="${FOUR[*]}"; fi
    for try in $(seq 1 "$MAX_TRIES"); do
        left=$(secs_left); need=${RUN_SECS[$g]:-7200}
        if [ "$left" -lt "$need" ]; then
            log "gpus=$g $tag: ${left}s left on the allocation, a run needs ~${need}s; not starting it"
            break
        fi
        # Keep a failed attempt's logs next to the result directory.
        [ -d "$OUT/gpus${g}_$tag" ] && mv "$OUT/gpus${g}_$tag" "$OUT/gpus${g}_${tag}_failed_$(date +%m%d_%H%M)"
        log "starting gpus=$g $tag on $nodes (attempt $try/$MAX_TRIES)"
        FITPP_NO_HOLD=1 CLIENT_NODES="$nodes" "$SCRIPT_DIR/arc_cxl_pool_series.sh" "$g" "$tag"
        done_run "$g" "$tag" && break
        log "gpus=$g $tag attempt $try produced no result (see $OUT/gpus${g}_$tag/launcher.log)"
    done
done
finish "DONE"
