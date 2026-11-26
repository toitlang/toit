#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# f2/f1 over several sessions: for each benchmark (of the first f1 log), the
# median over sessions of the per-session medians (each a median of 7 runs)
# for f1 and f2, the ratio, the spread of the f2 session medians
# ((max-min)/median), and the ratio and f2 time of an earlier log pair.
# Usage: bench-agg.sh "F1-LOGS" "F2-LOGS" EARLIER-F1-LOG EARLIER-F2-LOG
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
read -r -a F1 <<< "$1"
read -r -a F2 <<< "$2"
E1=$3
E2=$4
med() {  # bench logs...
  local b=$1; shift
  for n in "$@"; do
    grep -a "^BENCH $b " "$A/logs/$n.txt" | sed -n 's/.* median \([0-9]*\) .*/\1/p' | head -1
  done | sort -n | awk '{v[NR]=$1} END {if (NR==0) {print "- - -"; exit} m=v[int((NR+1)/2)]; printf "%d %d %d\n", m, v[1], v[NR]}'
}
benches=$(grep -a "^BENCH " "$A/logs/${F1[0]}.txt" | awk '$3 == "min" {print $2}')
printf '| %-14s | %9s | %9s | %6s | %7s | %9s | %6s |\n' bench "f1 ms" "f2 ms" "f2/f1" "f2 sprd" "earlier f2" "earlier"
for b in $benches; do
  read -r m1 _ _ <<< "$(med "$b" "${F1[@]}")"
  read -r m2 lo2 hi2 <<< "$(med "$b" "${F2[@]}")"
  read -r e1 _ _ <<< "$(med "$b" "$E1")"
  read -r e2 _ _ <<< "$(med "$b" "$E2")"
  awk -v b="$b" -v m1="$m1" -v m2="$m2" -v lo="$lo2" -v hi="$hi2" -v e1="$e1" -v e2="$e2" 'BEGIN {
    er = (e1 > 0 && e2 > 0) ? sprintf("%.2f", e2 / e1) : "-"
    et = (e2 > 0) ? sprintf("%.1f", e2 / 1000) : "-"
    printf "| %-14s | %9.1f | %9.1f | %6.2f | %6.1f%% | %9s | %6s |\n", b, m1 / 1000, m2 / 1000, m2 / m1, 100 * (hi - lo) / m2, et, er
  }'
done
