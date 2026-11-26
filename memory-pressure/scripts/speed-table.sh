#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-final: the speed table of the report, per benchmark of KIND (bench =
# hwbench, perf = perfbench): f1 and f2 now and in esp32-layout's final
# state (fin3), each the mean over the four code-pad builds of the build's
# median (the unpadded build now: the mean of its three sessions), with the
# spread (max - min) / mean over the builds; f2/f1 now and then; f2 now /
# f2 then; and the spread of the three sessions of the unpadded build
# (session noise) for f1 and f2.
# Usage: speed-table.sh KIND
set -uo pipefail
K=$1
N=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure/logs
L=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout/logs
med() { grep -a "^BENCH $1 " "$2" 2> /dev/null | sed -n 's/.* median \([0-9]*\) .*/\1/p' | head -1; }
# builds: "file[,file...];file..." -> mean (ms), spread (%)
agg() {  # bench builds
  local b=$1 spec=$2 build f
  IFS=';' read -r -a builds <<< "$spec"
  for build in "${builds[@]}"; do
    IFS=',' read -r -a files <<< "$build"
    for f in "${files[@]}"; do med "$b" "$f"; done | awk 'NF {s += $1; n++} END {if (n) printf "%f\n", s / n}'
  done | awk 'NF {s += $1; n++; if (n == 1 || $1 < lo) lo = $1; if (n == 1 || $1 > hi) hi = $1}
              END {if (n == 0) print "0 0"; else printf "%.1f %.1f\n", s / n / 1000, 100 * (hi - lo) / (s / n)}'
}
F1="$N/b1-f1-fin-$K-r1.txt,$N/b2-f1-fin-$K-r2.txt,$N/b1-f1-fin-$K-r3.txt;$N/b2-f1-p2400-fin-$K-r1.txt;$N/b1-f1-p6272-fin-$K-r1.txt;$N/b2-f1-p11104-fin-$K-r1.txt"
F2="$N/b2-f2-fin-$K-r1.txt,$N/b1-f2-fin-$K-r2.txt,$N/b2-f2-fin-$K-r3.txt;$N/b1-f2-p2400-fin-$K-r1.txt;$N/b2-f2-p6272-fin-$K-r1.txt;$N/b1-f2-p11104-fin-$K-r1.txt"
S1="$N/b1-f1-fin-$K-r1.txt;$N/b2-f1-fin-$K-r2.txt;$N/b1-f1-fin-$K-r3.txt"
S2="$N/b2-f2-fin-$K-r1.txt;$N/b1-f2-fin-$K-r2.txt;$N/b2-f2-fin-$K-r3.txt"
L1="$L/b1-f1-fin3-$K-r1.txt;$L/b2-f1-p2400-fin3-$K-r1.txt;$L/b1-f1-p6272-fin3-$K-r1.txt;$L/b2-f1-p11104-fin3-$K-r1.txt"
L2="$L/b2-f2-fin3-$K-r1.txt;$L/b1-f2-p2400-fin3-$K-r1.txt;$L/b2-f2-p6272-fin3-$K-r1.txt;$L/b1-f2-p11104-fin3-$K-r1.txt"
benches=$(grep -a "^BENCH " "$N/b1-f1-fin-$K-r1.txt" | awk '$3 == "min" {print $2}')
echo "| bench ($K) | f1 | f2 | layout f1 | layout f2 | f2/f1 | layout f2/f1 | f2 / layout f2 | unpadded sessions f1 / f2 |"
echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|"
for b in $benches; do
  read -r f1 f1s <<< "$(agg "$b" "$F1")"
  read -r f2 f2s <<< "$(agg "$b" "$F2")"
  read -r l1 l1s <<< "$(agg "$b" "$L1")"
  read -r l2 l2s <<< "$(agg "$b" "$L2")"
  read -r _ s1 <<< "$(agg "$b" "$S1")"
  read -r _ s2 <<< "$(agg "$b" "$S2")"
  awk -v b="$b" -v f1="$f1" -v f1s="$f1s" -v f2="$f2" -v f2s="$f2s" -v l1="$l1" -v l1s="$l1s" -v l2="$l2" -v l2s="$l2s" -v s1="$s1" -v s2="$s2" '
    function r(a, c) { return (a > 0 && c > 0) ? sprintf("%.2f", a / c) : "-" }
    BEGIN { printf "| %s | %.1f (%.1f%%) | %.1f (%.1f%%) | %.1f (%.1f%%) | %.1f (%.1f%%) | %s | %s | %s | %.1f%% / %.1f%% |\n",
            b, f1, f1s, f2, f2s, l1, l1s, l2, l2s, r(f2, f1), r(l2, l1), r(f2, l2), s1, s2 }'
done
