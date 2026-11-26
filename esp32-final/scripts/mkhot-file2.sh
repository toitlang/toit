#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: writes hot_flash_functions.txt (v3). Group A per format =
# the functions with the most fetch-stall samples per byte in two unpinned
# layouts (STALLBUDGET bytes; mkhot.sh over the f*stall i-stall tables),
# then the functions with the largest time share per byte over the device
# benchmarks (mkhot.sh NORM=all over the per-benchmark cycle tables) until
# BUDGET bytes of code; lines in both formats' lists first (unprefixed),
# then "f2:", then "f1:". Group B: EXTRA (format 2: the verifier).
# Usage: mkhot-file2.sh BUDGET STALLBUDGET OUT HEADER EXTRA
set -uo pipefail
S=$(dirname "$0")
A=$(cd "$S/.." && pwd)
BUDGET=$1; SB=$2; OUT=$3; HEADER=$4; EXTRA=$5
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
for f in f2 f1; do
  VERBOSE=1 bash "$S/mkhot.sh" "$SB" "$A/logs/fs-${f}stall-base-i.tsv" "$A/logs/fs-${f}stall-p2400-base-i.tsv" | grep -v '^total' > "$T/$f.s"
  NORM=all VERBOSE=1 bash "$S/mkhot.sh" 1000000 "$A"/logs/bt-$f-pin1c/*.tsv | grep -v '^total' > "$T/$f.t"
  # Merge: the stall list, then the time list without duplicates, while
  # the code fits BUDGET.
  IRT=""; [ $f = f2 ] && IRT=$(cat "$S/iram-ir4.txt")
  awk -F'\t' -v budget="$BUDGET" -v irt="$IRT" '
    BEGIN { n = split(irt, ir, ",") }
    function iniram(g,   i) { for (i = 1; i <= n; i++) if (length(ir[i]) > 6 && substr(g, length(g) - length(ir[i]) + 1) == ir[i]) return 1; return 0 }
    iniram($1) { next }
    FNR == NR { if (!($1 in seen)) { seen[$1] = 1; used += $2; print }; next }
    !($1 in seen) && used + $2 <= budget { seen[$1] = 1; used += $2; print }
  ' "$T/$f.s" "$T/$f.t" > "$T/$f"
  awk -F'\t' -v f=$f '{s += $2} END {print f " group A " s " B, " NR " functions"}' "$T/$f" >&2
done
{
  cat "$HEADER"
  echo
  echo "# Group A, both formats (first the most fetch misses per byte, then"
  echo "# the largest share of the time per byte)."
  awk -F'\t' 'FNR == NR { a[$1] = 1; next } ($1 in a) { printf "%-72s # %5d B  %s\n", $1, $2, substr($4, 1, 60) }' "$T/f1" "$T/f2"
  echo
  echo "# Group A, format 2 only."
  awk -F'\t' 'FNR == NR { a[$1] = 1; next } !($1 in a) { printf "f2:%-69s # %5d B  %s\n", $1, $2, substr($4, 1, 60) }' "$T/f1" "$T/f2"
  echo
  echo "# Group A, format 1 only."
  awk -F'\t' 'FNR == NR { a[$1] = 1; next } !($1 in a) { printf "f1:%-69s # %5d B  %s\n", $1, $2, substr($4, 1, 60) }' "$T/f2" "$T/f1"
  echo
  echo "# Group B, format 2: the install-time verifier, the whole toit_vmverify"
  echo "# and toit_spec crates in their original order."
  grep -v '^#' "$EXTRA" | grep -v '^$' | sed 's/^/f2:/'
} > "$OUT"
