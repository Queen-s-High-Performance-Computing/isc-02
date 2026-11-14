#!/usr/bin/env bash
# LOCAL ONLY (macOS dev laptops): profile one playback of each demo with the
# built-in `sample` profiler. No special build needed; uses doom/doomgeneric
# as built (it has -ggdb3 symbols). On Linux use gprof/perf instead.
#
# Usage: scripts/profile_mac.sh [outdir] [demo...]
# Output: <outdir>/<demo>.sample.txt (full call tree) and a top-of-stack
#         summary printed to stdout.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/results/prof}
shift || true
DEMOS=("${@:-demo1 demo2 demo3}")
[ $# -eq 0 ] && DEMOS=(demo1 demo2 demo3)
mkdir -p "$OUT"

for d in "${DEMOS[@]}"; do
    work="$OUT/w_$d"; mkdir -p "$work"
    (
        cd "$work"
        start=$(date +%s.%N)
        DG_REFERENCE="$ROOT/reference/$d.txt" "$ROOT/doom/doomgeneric" \
            -iwad "$ROOT/freedoom1.wad" -timedemo "$d" > "$OUT/$d.log" 2>&1 &
        pid=$!
        # 1 ms interval for SAMPLE_SECS (default 2 s). Must be shorter than the
        # demo: sample fails to write its report if the process exits first.
        sample "$pid" "${SAMPLE_SECS:-2}" 1 -file "$OUT/$d.sample.txt" >/dev/null 2>&1 || true
        wait "$pid" || true
        end=$(date +%s.%N)
        echo "== $d: wall $(echo "$end - $start" | bc) s; $(grep -E 'timed|DGVALID' "$OUT/$d.log" | tr '\n' ' ')"
    )
    # Self-time ("top of stack") summary
    awk '/Sort by top of stack/{f=1;next} f&&NF{print} /Binary Images/{exit}' \
        "$OUT/$d.sample.txt" | head -25
done
