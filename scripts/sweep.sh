#!/usr/bin/env bash
# Tuning helper (not used by the scorer). Run INSIDE a job on frnt201:
#
#   salloc --time=01:00:00 --cpus-per-task=16 --mem-per-cpu=1G
#   module load gcc
#   scripts/sweep.sh flags  demo1     # compare compiler flags
#   scripts/sweep.sh copies demo1     # compare copy counts / modes / pinning
#
# Each line is one 30 s scorer run. Shared nodes are noisy: repeat anything
# that looks like a win, and only trust differences bigger than the spread.
# Leaves the default build (-O3 -march=native) in place when it finishes.

set -u
cd "$(dirname "$0")/.."
WHAT=${1:-flags}
DEMO=${2:-demo1}
SECS=${SECS:-30}

score() { scripts/score.sh "$DEMO" "$SECS" 1 | awk '/^  run 1:/ { print $3, "valid,", $6, "invalid" }'; }

case $WHAT in
flags)
    for opt in "-O2" "-O3" "-O2 -march=native" "-O3 -march=native" \
               "-O3 -march=native -flto=auto" "-O3 -march=native -funroll-loops"; do
        make -C doom clean > /dev/null
        make -C doom -j"$(nproc)" OPT="$opt" > /dev/null 2>&1 || { echo "$opt: build failed"; continue; }
        printf '%-40s %s\n' "$opt" "$(score)"
    done
    make -C doom clean > /dev/null && make -C doom -j"$(nproc)" > /dev/null 2>&1
    ;;
copies)
    # Scaling curve. run.sh fills one CPU per physical core first, then the
    # hyperthread siblings, so on a 16-CPU job that is 8 cores x 2 threads:
    #   COPIES <= 8  -> one copy per core (shows how per-core speed holds up)
    #   COPIES = 16  -> two copies per core (shows what hyperthreads add)
    # "per copy" = demos per copy per second, the number to scale up with.
    # Each copy loses on average half a demo when the timer cuts it off, so
    # the rate is (valid/copies + 0.5) / seconds.
    n=$(nproc)
    for c in 1 2 4 8 12 16 24 32 64 128; do
        [ "$c" -le "$n" ] || break
        r=$(COPIES=$c score)
        v=${r%% *}
        printf 'COPIES=%-4s MODE=fork    PIN=1  %-22s per copy %s/s\n' "$c" "$r" \
            "$(awk -v v="$v" -v c="$c" -v s="$SECS" 'BEGIN { printf "%.3f", (v / c + 0.5) / s }')"
    done
    for m in loop restart; do
        printf 'COPIES=%-4s MODE=%-8s PIN=1  %s\n' "$n" "$m" "$(COPIES=$n MODE=$m score)"
    done
    printf 'COPIES=%-4s MODE=fork    PIN=0  %s\n' "$n" "$(COPIES=$n PIN=0 score)"
    ;;
*)
    echo "usage: $0 flags|copies [demo]"; exit 1 ;;
esac
