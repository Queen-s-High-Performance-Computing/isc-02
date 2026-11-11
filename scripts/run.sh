#!/usr/bin/env bash
# TEAM-OWNED: how your team launches Doom. Change it however you like.
#
# scripts/score.sh starts this, waits for the time limit, then kills every
# process it started. Demos still running at that moment don't count.
#
# score.sh provides: DOOM_BIN DOOM_IWAD DOOM_DEMO DG_REFERENCE RESULTS_DIR
#
# Must-follow rules (see RULES.md):
#   - run everything on this node: no srun, sbatch or ssh
#   - keep every process in this process group: no setsid, nohup or disown
#   - send each copy's output to a *.log file in $RESULTS_DIR
#
# Strategy:
#   - One long-lived copy per CPU. Each copy loads the game data once, then
#     plays the demo over and over (MODE below), so start-up is paid once.
#   - Copies are spread over physical cores first, then over the second
#     hyperthread of each core, and each copy is pinned to its own CPU so its
#     caches stay warm and copies never migrate.
#
# Knobs (environment variables, for tuning runs; defaults are the submission):
#   COPIES=<n>   how many copies (default: every CPU this job may use)
#   MODE=fork    load once, fork a fresh child per demo (default; frames are
#                bit-identical to a fresh process)
#        loop    load once, replay the demo inside the same process
#        restart start a new Doom process for every demo (the original kit)
#   PIN=1|0      pin each copy to one CPU (default 1)

MODE=${MODE:-fork}
PIN=${PIN:-1}

# CPUs this job is allowed to use (respects the Slurm allocation).
allowed=$(awk '/^Cpus_allowed_list/ { print $2 }' /proc/self/status)
cpus=()
IFS=, read -ra ranges <<< "$allowed"
for r in "${ranges[@]}"; do
    if [[ $r == *-* ]]; then
        for ((c = ${r%-*}; c <= ${r#*-}; c++)); do cpus+=("$c"); done
    else
        cpus+=("$r")
    fi
done

# Order them so the first thread of every physical core comes first, then
# the hyperthread siblings: with COPIES = number of cores, each copy gets a
# core to itself.
ordered=()
if command -v lscpu > /dev/null; then
    declare -A allowed_set seen_core
    for c in "${cpus[@]}"; do allowed_set[$c]=1; done
    second=()
    while IFS=, read -r cpu core socket; do
        [[ $cpu == \#* || -z ${allowed_set[$cpu]} ]] && continue
        key="$socket:$core"
        if [[ -z ${seen_core[$key]} ]]; then
            seen_core[$key]=1
            ordered+=("$cpu")
        else
            second+=("$cpu")
        fi
    done < <(lscpu -p=CPU,CORE,SOCKET)
    ordered+=("${second[@]}")
fi
[ ${#ordered[@]} -eq ${#cpus[@]} ] || ordered=("${cpus[@]}")

COPIES=${COPIES:-${#ordered[@]}}

args=(-iwad "$DOOM_IWAD" -timedemo "$DOOM_DEMO")

for ((i = 0; i < COPIES; i++)); do
    workdir="$RESULTS_DIR/w$i"   # each copy needs its own folder for its config file
    mkdir -p "$workdir"
    pin=()
    if [ "$PIN" = 1 ]; then
        pin=(taskset -c "${ordered[i % ${#ordered[@]}]}")
    fi
    (
        cd "$workdir" || exit 1
        case $MODE in
            fork)    exec "${pin[@]}" "$DOOM_BIN" "${args[@]}" -demofork ;;
            loop)    exec "${pin[@]}" "$DOOM_BIN" "${args[@]}" -demoloop ;;
            restart) while true; do "${pin[@]}" "$DOOM_BIN" "${args[@]}" || true; done ;;
        esac
    ) > "$RESULTS_DIR/w$i.log" 2>&1 &
done
wait
