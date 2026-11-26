#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: assembles README.md from the head part, the tail with
# placeholders and the generated tables.
# Usage: readme-assemble.sh HEAD-PART TAIL-PART HEAD-COMMIT
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
L=$A/logs
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
{ echo "| bench | base | v1 | v1+f2ir | v2 | v2+ir2 | v2+ir4 | final (v3+ir4) |"
  echo "|---|---:|---:|---:|---:|---:|---:|---:|"
  grep -v "^| bench" "$L/table-f2-iterations.txt" | sed 's/ *$//; s/$/ |/'; } > "$T/ITERATIONS-F2"
{ echo "| bench | f1 base | f1 v1 | f1 final |"
  echo "|---|---:|---:|---:|"
  cat "$L/table-f1-iterations-bench.txt" "$L/table-f1-iterations-perf.txt" | grep -v "^| bench" | sed 's/ *$//; s/$/ |/'; } > "$T/ITERATIONS-F1"
{ echo "| bench | f1 base | f1 final | f2 base | f2 final |"
  echo "|---|---:|---:|---:|---:|"
  grep -v "^| bench" "$L/table-datapads.txt" | sed 's/ *$//; s/$/ |/'; } > "$T/DATA-PADS"
head -45 "$L/iram-rank-final.md" > "$T/IRAM-TABLE"
cp "$L/table-final-esp32.txt" "$T/FINAL-SPEED"
cp "$L/table-installs.md" "$T/INSTALLS"
cp "$L/readme-sizes.md" "$T/SIZES"
cp "$L/readme-other.md" "$T/OTHER"
cp "$L/readme-boards.md" "$T/BOARDS"
cp "$L/readme-suite.md" "$T/SUITE"
cp "$L/readme-short.md" "$T/SHORT-VERSION"
cat "$1" "$2" | awk -v dir="$T" -v head="$3" '
  { gsub(/HEAD-COMMIT/, head) }
  /^[A-Z][A-Z0-9-]+$/ { f = dir "/" $0; if ((getline line < f) > 0) { print line; while ((getline line < f) > 0) print line; close(f); next } }
  { print }' > "$A/README.md"
grep -n -E "^[A-Z][A-Z0-9-]+$" "$A/README.md" || echo "all placeholders filled"
