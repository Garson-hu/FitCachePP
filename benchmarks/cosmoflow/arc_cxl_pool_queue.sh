#!/bin/bash
#
# arc_cxl_pool_queue.sh [repeats]
#
# Works through the ARC CXL-tier CosmoFlow series one run at a time (all runs
# share the 8 CXL pools on the server node, so they cannot overlap). Each run
# is one call of arc_cxl_pool_series.sh.
#
# The 16 GB GPU nodes span three CPU generations and the CosmoFlow step time
# follows the CPU (about 130 ms/step on turin nodes, 190-210 ms on siena and
# rome); the CLASS map below says which classes each scale may use.
#
# At every run boundary it picks the first run that is pending, has enough idle
# nodes of its classes, and fits in the time left on this node's own SLURM job
# (which kills everything here when it ends): 16-GPU runs first, then 8-GPU,
# then 4/2/1 GPUs by repeat, shortest first. Finished runs are recognised by
# train.py's "Total epoch time" line, so the queue can be restarted at any
# point.

set -u
REPEATS="${1:-3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../sites/_resolve.sh" > /dev/null
OUT="${FITPP_RESULTS_ROOT}/arc_cxl_pool_series"
EXCLUDE_NODES="${EXCLUDE_NODES:-c54 c0 c1 c3}"   # see arc_cxl_pool_series.sh

# Wall-time per run: the slowest (rome/mixed) node sets have taken 1.6x the
# siena times, and a 4-GPU run on c2/c23/c24/c50 ran into its 4 h hold on
# 2026-10-08. Hold = generous; NEED = what must still be left on this node's job.
declare -A NEED_HOURS=([1]=12 [2]=6 [4]=4 [8]=3 [16]=2)
declare -A HOLD=([1]=16 [2]=8 [4]=6 [8]=4 [16]=3)
# The IPDPS runs used turin nodes for 2/4/8 GPUs, siena for 1 and siena+rome
# for 16. The user decided (2026-10-05) that matching the class is not
# required. rome nodes (c23, c24, c73-c79; kernel 5.19 elrepo) are left out
# since 2026-10-08: on them the training process grows by ~3.5 MB per file
# read and gets OOM-killed, while turin/siena stay at ~3 GB.
ALL_CLASSES="turin siena"
# 1 GPU stays on siena: the one 1-GPU run that got through its cold epoch ran
# on c65, and a 1-GPU run on c23 (rome) was SIGKILLed after an hour (2026-10-07).
# 2026-10-09: the user wants the CXL numbers compared with the PMem bars on
# equal footing, so 2/4/8 GPUs are rerun on turin only (the IPDPS node class
# for those scales); runs that mixed in siena nodes were set aside under
# node_mismatch/.
declare -A CLASS=([1]="siena" [2]="turin" [4]="turin" [8]="turin" [16]="$ALL_CLASSES")

log()  { echo "[$(date '+%F %T')] $*"; }
done_run()  { grep -qs 'Total epoch time' "$OUT/gpus$1_rep$2"/horovodrun_*.log; }
tried_run() { [ -e "$OUT/gpus$1_rep$2/FAILED" ]; }
pending()   { ! done_run "$1" "$2" && ! tried_run "$1" "$2"; }
idle_nodes() {   # idle GPU nodes of the class used for <gpus>
    comm -12 <(sinfo -h -p "$FITPP_SLURM_PARTITION" -t idle -o '%n' | grep -vxF -f <(printf '%s\n' $EXCLUDE_NODES) | sort -u) \
             <(sinfo -h -p "${CLASS[$1]// /,}" -o '%n' | sort -u) | wc -l
}
# Hours left on this node's SLURM job (squeue %L is [D-]HH:MM:SS).
hours_left() {
    local l; l=$(squeue -h -u "$USER" -w "$(hostname -s)" -t R -o '%L' | head -1)
    [ -z "$l" ] && { echo 0; return; }
    local d=0; [[ "$l" == *-* ]] && { d=${l%%-*}; l=${l#*-}; }
    IFS=: read -r h m s <<< "$l"; [ -z "${s:-}" ] && { h=0; }
    echo $(( 10#$d * 24 + 10#$h ))
}
fits()     { [ "$left" -ge "${NEED_HOURS[$1]}" ]; }
runnable() { pending "$1" "$2" && fits "$1" && [ "$(idle_nodes "$1")" -ge "$1" ]; }
pick_run() {   # prints "<gpus> <rep>"
    local rep g
    for g in 16 8; do
        for rep in $(seq 1 "$REPEATS"); do runnable "$g" "$rep" && { echo "$g $rep"; return; }; done
    done
    for rep in $(seq 1 "$REPEATS"); do
        for g in 4 2 1; do runnable "$g" "$rep" && { echo "$g $rep"; return; }; done
    done
}
something_left() {   # a pending run that would still fit, if its nodes were idle
    local rep g
    for rep in $(seq 1 "$REPEATS"); do
        for g in 16 8 4 2 1; do pending "$g" "$rep" && fits "$g" && return 0; done
    done
    return 1
}

while true; do
    # Another run (or a stray server) still owns the pools: wait.
    if pgrep -f 'arc_cxl_pool_series.sh [0-9]' > /dev/null || pgrep -x fitcache_server > /dev/null; then
        sleep 60; continue
    fi
    # famfs on CXL memory is wiped by a reboot (happened 2026-10-07 18:51);
    # the user-owned project dir then needs the sudo famfs-mkdir bootstrap.
    if [ ! -d /mnt/famfs/dax2.0/ghu4_deeptier ]; then
        log "famfs project dir /mnt/famfs/dax2.0/ghu4_deeptier is missing (fresh mount?); stopping — re-create it with sudo /usr/local/bin/famfs-mkdir and restart"
        break
    fi
    left=$(hours_left)
    pick=$(pick_run)
    if [ -z "$pick" ]; then
        something_left || { log "nothing left that fits (job hours left: $left)"; break; }
        sleep 300; continue          # waiting for nodes of the right class
    fi
    read -r g rep <<< "$pick"
    log "starting gpus=$g rep$rep on ${CLASS[$g]} nodes (job hours left: $left)"
    NODE_CLASS="${CLASS[$g]}" HOLD_HOURS="${HOLD[$g]}" "$SCRIPT_DIR/arc_cxl_pool_series.sh" "$g" "rep$rep"
    done_run "$g" "$rep" || { touch "$OUT/gpus${g}_rep$rep/FAILED"; log "gpus=$g rep$rep FAILED (see launcher.log)"; }
done
