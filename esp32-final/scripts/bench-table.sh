#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Median wall times (ms) of hwbench/perfbench logs side by side, with the
# ratio of each column to the first. The benchmarks are those of the first
# log. Usage: bench-table.sh LOG-NAME...  (logs/<name>.txt)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
names=("$@")
benches=$(grep -a "^BENCH " "$A/logs/${names[0]}.txt" | awk '$3 == "min" {print $2}')
printf '%-15s' bench
for n in "${names[@]}"; do printf ' %19s' "${n:0:19}"; done
echo
for b in $benches; do
  printf '%-15s' "$b"
  base=""
  for n in "${names[@]}"; do
    m=$(grep -a "^BENCH $b " "$A/logs/$n.txt" | sed -n 's/.* median \([0-9]*\) .*/\1/p' | head -1)
    if [ -z "$m" ]; then printf ' %19s' "-"; continue; fi
    if [ -z "$base" ]; then
      base=$m
      printf ' %19s' "$(awk -v m="$m" 'BEGIN{printf "%.1f", m/1000}')"
    else
      printf ' %19s' "$(awk -v m="$m" -v b="$base" 'BEGIN{printf "%.1f (%.2f)", m/1000, m/b}')"
    fi
  done
  echo
done
