#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: one func-samples.sh table per benchmark (MODE, default
# cycles: the dense time profile of the stall-sample builds) of the given
# logs of one build, written to OUTDIR/<bench>.tsv. mkhot.sh weighs every
# table equally, so every benchmark's flash working set counts the same.
# Usage: bench-tables.sh BIN-NAME OUTDIR LOG-NAME...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
BIN=$1
OUT=$2
shift 2
mkdir -p "$OUT"
benches=$(for L in "$@"; do tr -d '\r' < "$A/logs/$L.txt" | awk '/\[hw-perf\] begin /{print $3}'; done | sort -u)
for b in $benches; do
  MODE=${MODE:-cycles} bash "$A/scripts/func-samples.sh" "$BIN" "^$b\$" "$@" > "$OUT/$b.tsv"
done
ls "$OUT" | wc -l
