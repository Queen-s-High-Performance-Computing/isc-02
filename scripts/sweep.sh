#!/usr/bin/env bash
# Tuning helper (not used by the scorer). Run INSIDE a job on frnt201:
#
#   salloc -A sg6079000 -w frnt201 --time=01:00:00 --cpus-per-task=16 --mem-per-cpu=1G
#   module load gcc
#   scripts/sweep.sh all            # everything below, about 25 minutes
#
#   scripts/sweep.sh valid          # demo1-3 with the defaults: must be 0 invalid
#   scripts/sweep.sh ht     [demo]  # hyperthreads: 1 copy per core, 2 copies,
#                                   # 2 copies sharing one frame buffer
#   scripts/sweep.sh flags  [demo]  # compiler flags and vector width
#   scripts/sweep.sh cc     [demo]  # other compilers (needs "module")
#   scripts/sweep.sh copies [demo]  # scaling curve: 1, 2, 4, ... copies
#
# Every line of output is one scorer run (SECS seconds, default 30):
#
#   <setting>  valid/invalid  copies  s/demo  demos/s  MHz
#
#   valid     what scripts/score.sh counted (the official number)
#   s/demo    average time one copy took per demo, from the "timed" line
#             every demo prints. Far less jumpy than the count, which
#             loses up to one unfinished demo per copy when the clock stops.
#   demos/s   copies / (s/demo): the number to compare settings by
#   MHz       average clock of this job's CPUs 10 s into the run
#
# Settings are run in turn, REPS times over (default 3), so slow drift on
# a shared node hits all of them alike. The summary gives the median.
# Leaves the default build in place when it finishes.

set -u
cd "$(dirname "$0")/.."
WHAT=${1:-all}
DEMO=${2:-demo1}
SECS=${SECS:-30}
REPS=${REPS:-3}
OUT=${OUT:-benchmarks/sweep-$(hostname -s)-$(date +%Y%m%d-%H%M%S).txt}
mkdir -p "$(dirname "$OUT")"

say() { echo "$@" | tee -a "$OUT"; }

build() {   # build [make args...]; returns non-zero if the build fails
    make -C doom clean > /dev/null 2>&1
    make -C doom -j"$(nproc)" "$@" > /dev/null 2>&1
}

mhz() {     # average MHz of the CPUs this job may use
    awk -v list="$(awk '/^Cpus_allowed_list/ { print $2 }' /proc/self/status)" '
        BEGIN { n = split(list, r, ",")
                for (i = 1; i <= n; i++) { m = split(r[i], ab, "-"); lo = ab[1]; hi = (m > 1) ? ab[2] : ab[1]
                                           for (c = lo; c <= hi; c++) want[c] = 1 } }
        /^processor/ { cpu = $3 }
        /^cpu MHz/   { if (cpu in want) { s += $4; k++ } }
        END { if (k) printf "%.0f", s / k; else printf "?" }' /proc/cpuinfo
}

# one <label> [VAR=value ...]: one scorer run with those run.sh knobs.
# Prints the result line and appends "label demos_per_s valid" to $TMP.
one() {
    local label=$1; shift
    local demo=$DEMO
    mkdir -p results
    ( sleep "$((SECS < 20 ? SECS / 2 : 10))"; mhz > results/.mhz 2> /dev/null ) &
    local sampler=$!
    local line
    line=$(env "$@" scripts/score.sh "$demo" "$SECS" 1 | awk '/^  run 1:/ { print $3, $6 }')
    wait "$sampler" 2> /dev/null
    local valid=${line%% *} invalid=${line##* }
    local copies stats
    copies=$(ls results/run1/w*.log 2> /dev/null | wc -l)
    stats=$(cat results/run1/*.log 2> /dev/null | awk -v c="$copies" '
        /^timed / && $NF == "s" { s += $(NF - 1); n++ }
        END { if (n) printf "%.4f %.3f", s / n, c / (s / n); else printf "? ?" }')
    printf '%-34s %5s/%-3s %4s  %8s  %8s  %5s\n' "$label" "$valid" "$invalid" \
        "$copies" "${stats% *}" "${stats#* }" "$(cat results/.mhz 2> /dev/null)" | tee -a "$OUT"
    echo "$label|${stats#* }|$valid|$invalid" >> "$TMP"
}

summary() {  # median demos/s and median valid per label, best first
    say ""
    say "Summary (median of $REPS; best first):"
    awk -F'|' '
        { n[$1]++; r[$1, n[$1]] = $2; v[$1, n[$1]] = $3; bad[$1] += $4 }
        END {
            for (l in n) {
                k = n[l]
                for (i = 1; i <= k; i++) for (j = i + 1; j <= k; j++) {
                    if (r[l, j] < r[l, i]) { t = r[l, i]; r[l, i] = r[l, j]; r[l, j] = t }
                    if (v[l, j] < v[l, i]) { t = v[l, i]; v[l, i] = v[l, j]; v[l, j] = t }
                }
                m = int((k + 1) / 2)
                printf "%09.3f|%-34s %8.3f demos/s   (min %.3f, max %.3f)   valid %s   invalid %d\n",
                       r[l, m], l, r[l, m], r[l, 1], r[l, k], v[l, m], bad[l]
            }
        }' "$TMP" | sort -r | cut -d'|' -f2- | tee -a "$OUT"
    say "A setting only counts as better if its minimum beats the other's maximum,"
    say "or it wins clearly in every round. Any 'invalid' above 0 rules a setting out."
}

header() {
    say ""
    say "=== $1 ($DEMO, ${SECS}s runs) ==="
    printf '%-34s %9s %4s  %8s  %8s  %5s\n' setting valid/inv cop s/demo demos/s MHz | tee -a "$OUT"
    TMP=$(mktemp)
}

do_valid() {
    say ""
    say "=== valid: defaults on all three demos ==="
    local d
    for d in demo1 demo2 demo3; do
        scripts/score.sh "$d" "$SECS" 1 | grep -E "run 1|SCORE" | tee -a "$OUT"
        cat results/run1/*.log | grep DGVALID | sort | uniq -c | tee -a "$OUT"
    done
    say "Expected: 0 invalid; matched=7115 (or 7116) / 7088 / 6041."
}

do_ht() {
    header "ht: copies per physical core"
    local r
    for r in $(seq 1 "$REPS"); do
        one "1 per core (SMT=1)"            SMT=1
        one "2 per core (SMT=2)"            SMT=2
        one "2 per core, shared fb"         SMT=2 FBSHARE=1
    done
    summary
    say "Divide demos/s by the number of physical cores in this job for a per-core rate;"
    say "the full node has 64 cores. To make a setting the default, change the"
    say "SMT=\${SMT:-2} and FBSHARE=\${FBSHARE:-0} lines near the top of scripts/run.sh."
}

do_flags() {
    header "flags: one build per line, default run.sh settings"
    local base="-O3 -march=native -fwrapv -fno-strict-aliasing"
    local names=("default (make)" "no LTO" "LTO, -O2" "LTO, 512-bit spans" "LTO, no hand-written SIMD"
                 "LTO, prefer 512-bit vectors" "LTO, -funroll-loops")
    local opts=("" "$base" "-O2 -march=native -flto=auto -fwrapv -fno-strict-aliasing"
                "$base -flto=auto -DDOOM_SPAN_ZMM" "$base -flto=auto -DDOOM_NO_SIMD"
                "$base -flto=auto -mprefer-vector-width=512" "$base -flto=auto -funroll-loops")
    local r i
    for r in $(seq 1 "$REPS"); do
        for i in "${!names[@]}"; do
            if [ -z "${opts[i]}" ]; then build; else build OPT="${opts[i]}"; fi \
                || { say "${names[i]}: build failed"; continue; }
            one "${names[i]}"
        done
    done
    build
    summary
    say "To adopt a flag set, change the OPT line in doom/Makefile (on the laptop)."
}

do_cc() {
    header "cc: other compilers, default flags"
    if ! type module > /dev/null 2>&1; then
        say "'module' is not available in this shell; skipping."
        return
    fi
    local r spec name
    for r in $(seq 1 "$REPS"); do
        for spec in "gcc/12.3:gcc" "gcc/13.3:gcc" "gcc/14.3:gcc" "clang/18.1.8:clang"; do
            name=${spec%%:*}
            ( module load "$name" > /dev/null 2>&1 || exit 1
              if [ "${spec##*:}" = clang ]; then
                  build CC=clang OPT="-O3 -march=native -flto -fwrapv -fno-strict-aliasing"
              else
                  build
              fi ) || { say "$name: not available or build failed"; continue; }
            one "$name"
        done
    done
    module load gcc > /dev/null 2>&1
    build
    summary
    say "The organizers build with plain 'make -C doom', so another compiler only helps"
    say "if they agree to load its module first. Ask before relying on it."
}

do_copies() {
    header "copies: scaling curve (physical cores first, then second threads)"
    local n c
    n=$(nproc)
    for c in 1 2 4 8 12 16 24 32 48 64 96 128; do
        [ "$c" -le "$n" ] || break
        one "COPIES=$c" COPIES="$c"
    done
    one "COPIES=$n unpinned" PIN=0
    one "COPIES=$n loop mode" MODE=loop
    one "COPIES=$n original restart mode" MODE=restart
    rm -f "$TMP"
}

say "sweep.sh $WHAT on $(hostname) at $(date)"
say "CPUs: $(nproc) ($(awk '/^Cpus_allowed_list/ { print $2 }' /proc/self/status)); load: $(uptime | sed 's/.*load average: //')"
say "compiler: $(gcc --version | head -1)"
say "commit: $(git rev-parse --short HEAD 2> /dev/null) $(git status --short 2> /dev/null | wc -l) uncommitted file(s)"

case $WHAT in
    valid)  build && do_valid ;;
    ht)     build && do_ht ;;
    flags)  do_flags ;;
    cc)     do_cc ;;
    copies) build && do_copies ;;
    all)    build && do_valid && do_ht && DEMO=demo3 do_ht && do_flags ;;
    *)      echo "usage: $0 all|valid|ht|flags|cc|copies [demo]"; exit 1 ;;
esac
say ""
say "Saved to $OUT"
