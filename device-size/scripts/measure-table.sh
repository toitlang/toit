#!/usr/bin/env bash
# Side-by-side table of the TIME and MEM lines of suite runs.
# Usage: measure-table.sh TAG [CONFIGS...]
A=/home/flo/work/opentoit-sandbox-artifacts/device-size
TAG=$1
shift
CONFIGS=${*:-f1 f2cxx f2}
files=()
for c in $CONFIGS; do files+=("$A/qemu/run-$c-$TAG/measure.txt"); done
printf "%-28s" "measure"
for c in $CONFIGS; do printf " %14s" "$c"; done
printf " %8s\n" "last/1st"
paste "${files[@]}" | awk -F'\t' '{
  n = split($1, a, " ")
  key = a[1] == "MEM" ? "free " a[2] : a[2]
  printf "%-28s", key
  first = 0; last = 0
  for (i = 1; i <= NF; i++) {
    split($i, f, " ")
    v = f[1] == "MEM" ? f[4] : f[3]
    if (i == 1) first = v
    last = v
    printf " %14s", v
  }
  if (first > 0) printf " %8.3f", last / first
  printf "\n"
}'
