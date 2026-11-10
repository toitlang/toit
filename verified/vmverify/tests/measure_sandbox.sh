#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# Runs the sandbox ctests with TOIT_VERIFY_TIME=1 and summarizes every
# verification of an untrusted launch: count, bytecodes, peak memory (the
# counting allocator of vmverify) and total time (min, median, max).
#
# Usage: measure_sandbox.sh [BUILD_DIR]

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${1:-$HERE/../../../build/host}"
LOG="$(mktemp)"
ROWS="$(mktemp)"
trap 'rm -f "$LOG" "$ROWS"' EXIT
TOIT_VERIFY_TIME=1 ctest --test-dir "$BUILD" -R '^tests/sandbox/' -j "${JOBS:-8}" -V > "$LOG" 2>&1
# One row per verification: status, methods, bytecodes, objects, infer ms,
# check ms, total ms (convert + heap + infer + check), peak KB.
grep -o 'verifier: [a-z]*, [0-9]* methods, [0-9]* bytecodes, [0-9]* objects; convert [0-9.]* ms, heap [0-9.]* ms, infer [0-9.]* ms, check [0-9.]* ms; peak [0-9]* KB' "$LOG" \
  | sed -E 's/^verifier: ([a-z]*), ([0-9]*) methods, ([0-9]*) bytecodes, ([0-9]*) objects; convert ([0-9.]*) ms, heap ([0-9.]*) ms, infer ([0-9.]*) ms, check ([0-9.]*) ms; peak ([0-9]*) KB$/\1 \2 \3 \4 \5 \6 \7 \8 \9/' \
  | awk '{ printf "%s %s %s %s %s %s %.17g %s\n", $1, $2, $3, $4, $7, $8, $5 + $6 + $7 + $8, $9 }' > "$ROWS"

# Prints "MIN-MAX (median MEDIAN)" of column $1 of the rows, each value
# formatted with the printf format $2 (%d truncates a fractional median).
span() {
  awk -v c="$1" '{ print $c }' "$ROWS" | sort -g | awk -v fmt="$2" '
    { v[NR] = $1 }
    END {
      median = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
      printf "%s-%s (median %s)\n", sprintf(fmt, v[1]), sprintf(fmt, v[NR]), sprintf(fmt, median)
    }'
}

if [ ! -s "$ROWS" ]; then
  echo "no verifications found"
else
  echo "verifications: $(wc -l < "$ROWS") ($(awk '$1 == "accepted"' "$ROWS" | wc -l) accepted)"
  echo "methods: $(span 2 %d)"
  echo "bytecodes: $(span 3 %d)"
  echo "objects: $(span 4 %d)"
  echo "infer ms: $(span 5 %.1f)"
  echo "check ms: $(span 6 %.1f)"
  echo "total ms: $(span 7 %.1f)"
  echo "peak KB: $(span 8 %d)"
fi
grep -E '^[0-9]+% tests passed|tests failed' "$LOG" | tail -2
