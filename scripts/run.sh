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
#   - One Doom process is started per physical core. It loads the game data
#     once (into memory on that core's side of the machine), then starts one
#     worker per hardware thread of the core. Each worker pins itself to its
#     own CPU, writes to its own log (w<cpu>.log) and plays the demo over and
#     over, a fresh forked child per demo (see doom/d_workers.c, d_main.c).
#   - Nothing is started through taskset or a shell loop, so all copies are
#     running within a few milliseconds of the scorer starting the clock.
#
# Knobs (environment variables, for tuning runs; defaults are the submission):
#   SMT=2|1      hardware threads to use per physical core (default 2: every
#                CPU this job may use; 1 = one copy per core)
#   COPIES=<n>   cap on the number of copies (default: no cap). Physical
#                cores are filled first, then their second threads.
#   FBSHARE=0|1  1 = the two workers of a core take turns drawing into one
#                shared frame buffer instead of two private ones, so the pair
#                fits in the core's L2 cache (default 1; see d_workers.c)
#   MODE=fork    load once, fork a fresh child per demo (default; frames are
#                bit-identical to a fresh process)
#        loop    load once, replay the demo inside the same process
#        restart start a new Doom process for every demo (the original kit)
#   PIN=1|0      pin each copy to one CPU (default 1)

MODE=${MODE:-fork}
PIN=${PIN:-1}
SMT=${SMT:-2}
FBSHARE=${FBSHARE:-1}

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

# Which physical core each CPU belongs to (socket:core), straight from the
# kernel. If that is not readable, every CPU counts as its own core.
declare -A core_of nth
for c in "${cpus[@]}"; do
    t=/sys/devices/system/cpu/cpu$c/topology
    if [[ -r $t/core_id && -r $t/physical_package_id ]]; then
        core_of[$c]="$(< "$t/physical_package_id"):$(< "$t/core_id")"
    else
        core_of[$c]="cpu$c"
    fi
done

# Order the CPUs so the first thread of every core comes first, then the
# second threads, and keep at most SMT threads per core and COPIES in all.
first=() second=()
for c in "${cpus[@]}"; do
    k=${core_of[$c]}
    n=$(( ${nth[$k]:-0} + 1 ))
    nth[$k]=$n
    if [ "$n" -eq 1 ]; then
        first+=("$c")
    elif [ "$n" -le "$SMT" ]; then
        second+=("$c")
    fi
done
ordered=("${first[@]}" "${second[@]}")
COPIES=${COPIES:-${#ordered[@]}}
(( COPIES > ${#ordered[@]} )) && COPIES=${#ordered[@]}
ordered=("${ordered[@]:0:COPIES}")

# Group the chosen CPUs by core again: one Doom process per core.
declare -A members
cores=()
for c in "${ordered[@]}"; do
    k=${core_of[$c]}
    if [[ -z ${members[$k]} ]]; then
        cores+=("$k")
        members[$k]=$c
    else
        members[$k]+=",$c"
    fi
done

cd "$RESULTS_DIR" || exit 1

args=(-iwad "$DOOM_IWAD" -timedemo "$DOOM_DEMO")
extra=()
[ "$PIN" = 1 ] || extra+=(-nopin)
[ "$FBSHARE" = 1 ] && extra+=(-sharefb)

case $MODE in
    fork|loop)
        i=0
        for k in "${cores[@]}"; do
            "$DOOM_BIN" "${args[@]}" "-demo$MODE" -workers "${members[$k]}" \
                -worklog "$RESULTS_DIR/w" "${extra[@]}" \
                > "$RESULTS_DIR/core$i.log" 2>&1 &
            i=$((i + 1))
        done
        ;;
    restart)
        for c in "${ordered[@]}"; do
            pin=()
            [ "$PIN" = 1 ] && pin=(taskset -c "$c")
            ( while true; do "${pin[@]}" "$DOOM_BIN" "${args[@]}" || true; done ) \
                > "$RESULTS_DIR/w$c.log" 2>&1 &
        done
        ;;
    *)
        echo "run.sh: unknown MODE '$MODE' (fork, loop or restart)"
        exit 1
        ;;
esac
wait
