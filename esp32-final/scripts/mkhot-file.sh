#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: writes toolchains/idf/components/toit/hot_flash_functions.txt
# (the default list of TOIT_PIN_HOT_FLASH_CODE) from the stall-sample
# tables: group A per format (mkhot.sh, BUDGET bytes each; lines in both
# lists unprefixed and first, then the "f2:" and "f1:" ones), then group B
# (EXTRA, format 2 only: the verifier).
# Usage: mkhot-file.sh BUDGET "F2-TSV..." "F1-TSV..." EXTRA-FILE OUT HEADER-FILE
set -uo pipefail
S=$(dirname "$0")
BUDGET=$1; F2=$2; F1=$3; EXTRA=$4; OUT=$5; HEADER=$6
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# shellcheck disable=SC2086
VERBOSE=1 bash "$S/mkhot.sh" "$BUDGET" $F2 | grep -v '^total' > "$T/f2"
# shellcheck disable=SC2086
VERBOSE=1 bash "$S/mkhot.sh" "$BUDGET" $F1 | grep -v '^total' > "$T/f1"
{
  cat "$HEADER"
  echo
  echo "# Group A, both formats (largest share of the time per byte first)."
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
awk -F'\t' '{s += $2} END {print "f2 group A " s " B"}' "$T/f2" >&2
awk -F'\t' '{s += $2} END {print "f1 group A " s " B"}' "$T/f1" >&2
