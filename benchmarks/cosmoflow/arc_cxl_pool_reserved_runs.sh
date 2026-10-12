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
# the IPDPS 4-GPU node set (c50, c51, c54, c55, with c54 — broken GPU driver —
# replaced by c56). Runs that already have a result are skipped. DRY_RUN=1 only
# does the pre-flight checks.

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
if [ ! -d "$FAMFS_DIR" ]; then
    log "famfs project dir missing (fresh mount); re-creating it"
    sudo -n /usr/local/bin/famfs-mkdir -m 0755 "$FAMFS_DIR" || finish "ABORT: cannot re-create $FAMFS_DIR"
fi
for _ in $(seq 1 30); do pgrep -x fitcache_server > /dev/null || break; sleep 60; done
pgrep -x fitcache_server > /dev/null && finish "ABORT: servers of another run are still up on $(hostname -s)"
[ "${DRY_RUN:-0}" = "1" ] && finish "DRY_RUN OK: famfs ready, nodes ${NODES[*]}"

FOUR=(c50 c51 c55 c56)
for n in "${FOUR[@]}"; do
    printf '%s\n' "${NODES[@]}" | grep -qx "$n" || { FOUR=("${NODES[@]:0:4}"); break; }
done

for run in "8 rep1" "8 rep2" "8 rep3" "4 rep4" "4 rep5" "4 rep6"; do
    read -r g tag <<< "$run"
    done_run "$g" "$tag" && { log "gpus=$g $tag already done; skipping"; continue; }
    if [ "$g" = 8 ]; then nodes="${NODES[*]}"; else nodes="${FOUR[*]}"; fi
    log "starting gpus=$g $tag on $nodes"
    FITPP_NO_HOLD=1 CLIENT_NODES="$nodes" "$SCRIPT_DIR/arc_cxl_pool_series.sh" "$g" "$tag"
    done_run "$g" "$tag" || log "gpus=$g $tag produced no result (see $OUT/gpus${g}_$tag/launcher.log)"
done
finish "DONE"
