#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: the joint TOIT_HOT_FLASH_FUNCTIONS list for format 1 and 2.
# Group A: mkhot.sh of the f2 tables and of the f1 tables (BUDGET bytes
# each); the functions in both first (in the f2 order), then the f2-only
# ones, then the f1-only ones (in a build of one format the other's
# functions do not exist and match nothing, so each format gets its own
# list contiguous). Group B: the globs of EXTRA (one per line, e.g. the
# verifier's functions), after A. Prints one glob per line.
# Usage: mkhot-joint.sh BUDGET "F2-TSV..." "F1-TSV..." [EXTRA-FILE]
set -uo pipefail
S=$(dirname "$0")
BUDGET=$1
F2=$2
F1=$3
EXTRA=${4:-}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# shellcheck disable=SC2086
VERBOSE=1 bash "$S/mkhot.sh" "$BUDGET" $F2 | grep -v '^total' | cut -f1 > "$T/f2"
# shellcheck disable=SC2086
VERBOSE=1 bash "$S/mkhot.sh" "$BUDGET" $F1 | grep -v '^total' | cut -f1 > "$T/f1"
awk 'FNR == NR { a[$0] = 1; next } ($0 in a)' "$T/f1" "$T/f2" > "$T/shared"
awk 'FNR == NR { a[$0] = 1; next } !($0 in a)' "$T/shared" "$T/f2" > "$T/f2only"
awk 'FNR == NR { a[$0] = 1; next } !($0 in a)' "$T/shared" "$T/f1" > "$T/f1only"
cat "$T/shared" "$T/f2only" "$T/f1only"
[ -n "$EXTRA" ] && grep -v '^#' "$EXTRA" | grep -v '^$'
echo "shared $(wc -l < "$T/shared") f2-only $(wc -l < "$T/f2only") f1-only $(wc -l < "$T/f1only")" >&2
