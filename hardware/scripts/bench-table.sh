#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Median wall times (ms) of hwbench logs side by side, with the ratio of
# each column to the first. Usage: bench-table.sh LOG-NAME...  (logs/<name>.txt)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/hardware
names=("$@")
printf '%-12s' bench
for n in "${names[@]}"; do printf ' %22s' "$n"; done
echo
for b in richards deltablue pystone json map-set strings gc-stress loop-1M calls-200k; do
  printf '%-12s' "$b"
  base=""
  for n in "${names[@]}"; do
    m=$(grep -a "^BENCH $b " "$A/logs/$n.txt" | sed -n 's/.* median \([0-9]*\) .*/\1/p' | head -1)
    if [ -z "$m" ]; then printf ' %22s' "-"; continue; fi
    if [ -z "$base" ]; then
      base=$m
      printf ' %22s' "$(awk -v m="$m" 'BEGIN{printf "%.1f", m/1000}')"
    else
      printf ' %22s' "$(awk -v m="$m" -v b="$base" 'BEGIN{printf "%.1f (%.2f)", m/1000, m/b}')"
    fi
  done
  echo
done
printf '%-12s' boot-free
for n in "${names[@]}"; do printf ' %22s' "$(grep -a '^MEM boot' "$A/logs/$n.txt" | head -1 | awk '{print $4}')"; done
echo
