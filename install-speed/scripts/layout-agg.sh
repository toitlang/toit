#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Mean and spread over builds (layout perturbations) of each configuration:
# for each benchmark of the first log, per configuration the mean of the
# build medians (each a median of 7 runs), and the spread (max-min)/mean;
# ratios of every configuration's mean to the first configuration's.
# Usage: layout-agg.sh "NAME1:LOG LOG..." "NAME2:LOG LOG..." ...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/install-speed
names=(); logs=()
for spec in "$@"; do names+=("${spec%%:*}"); logs+=("${spec#*:}"); done
read -r -a first <<< "${logs[0]}"
benches=$(grep -a "^BENCH " "$A/logs/${first[0]}.txt" | awk '$3 == "min" {print $2}')
printf '| %-14s |' bench
for n in "${names[@]}"; do printf ' %s mean (spread) |' "$n"; done
for n in "${names[@]:1}"; do printf ' %s/%s |' "$n" "${names[0]}"; done
echo
for b in $benches; do
  printf '| %-14s |' "$b"
  means=()
  for i in "${!names[@]}"; do
    read -r -a L <<< "${logs[$i]}"
    r=$(for n in "${L[@]}"; do grep -a "^BENCH $b " "$A/logs/$n.txt" | sed -n 's/.* median \([0-9]*\) .*/\1/p' | head -1; done |
      awk 'NF {s += $1; n++; if (n == 1 || $1 < lo) lo = $1; if (n == 1 || $1 > hi) hi = $1}
           END {if (n == 0) print "- -"; else printf "%.1f %.1f\n", s / n / 1000, 100 * (hi - lo) / (s / n)}')
    read -r m s <<< "$r"
    means+=("$m")
    printf ' %s (%s%%) |' "$m" "$s"
  done
  for m in "${means[@]:1}"; do
    awk -v a="$m" -v b="${means[0]}" 'BEGIN { if (a == "-" || b == "-") printf " - |"; else printf " %.2f |", a / b }'
  done
  echo
done
