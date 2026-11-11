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

# Measures the VM's verifier with the shipped certificate against the
# inference (README.md, "Shipped certificates"): compiles each program in
# format 2 (toit.compile ships the certificate), then runs
# `toit.run --verify --require-certificate` and `--no-certificate` RUNS
# times each with TOIT_VERIFY_TIME=1 and prints one line per program:
#
#   name bytecodes methods certificate(bytes) fraction(%)
#        shipped: median-ms peak-KB  inferred: median-ms peak-KB
#
# Times are of the whole verification (conversion, heap check, inference
# and checker); the peak is the Rust heap high-water mark.
#
# Usage: measure_shipped.sh [--runs N] [--trusted] [--out DIR] PROGRAM.toit|PROGRAM.snapshot...

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BUILD="${BUILD:-$REPO/build/host}"
BIN="$BUILD/sdk/lib/toit/bin"
RUNS=5
TRUSTED=()
OUT="$REPO/build/measure-shipped"
PROGRAMS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) shift; RUNS="$1" ;;
    --trusted) TRUSTED=(--trusted) ;;
    --out) shift; OUT="$1" ;;
    *) PROGRAMS+=("$1") ;;
  esac
  shift
done
mkdir -p "$OUT"

# The median of the numbers on stdin.
median() {
  sort -n | awk '{ a[NR] = $1 } END { if (NR == 0) print "-"; else print a[int((NR + 1) / 2)] }'
}

# Runs the verifier RUNS times with the given option; prints "ms KB" or "- -".
measure() {
  local snap="$1" option="$2"
  local times=() peaks=()
  for _ in $(seq "$RUNS"); do
    local line
    line=$(TOIT_VERIFY_TIME=1 "$BIN/toit.run" --verify ${TRUSTED[@]+"${TRUSTED[@]}"} "$option" "$snap" 2>&1 \
        | grep '^verifier: accepted' || true)
    [ -z "$line" ] && { echo "- -"; return; }
    local convert heap infer check peak
    convert=$(sed -E 's/.*convert ([0-9.]+) ms.*/\1/' <<< "$line")
    heap=$(sed -E 's/.*heap ([0-9.]+) ms.*/\1/' <<< "$line")
    infer=$(sed -E 's/.*infer ([0-9.]+) ms.*/\1/' <<< "$line")
    check=$(sed -E 's/.*check ([0-9.]+) ms.*/\1/' <<< "$line")
    peak=$(sed -E 's/.*peak ([0-9]+) KB.*/\1/' <<< "$line")
    times+=("$(awk -v a="$convert" -v b="$heap" -v c="$infer" -v d="$check" 'BEGIN { printf "%.1f", a + b + c + d }')")
    peaks+=("$peak")
  done
  echo "$(printf '%s\n' "${times[@]}" | median) $(printf '%s\n' "${peaks[@]}" | median)"
}

for p in "${PROGRAMS[@]}"; do
  name="$(basename "$p")"
  name="${name%.*}"
  snap="$OUT/$name.snapshot"
  case "$p" in
    *.snapshot) cp "$p" "$snap" ;;
    *) (cd "$REPO" && "$BIN/toit.compile" -Xbytecode_format=2 -w "$snap" "$p") || { echo "$name compile-error"; continue; } ;;
  esac
  cert=$(ar p "$snap" certificate 2> /dev/null | wc -c)
  info=$(TOIT_VERIFY_TIME=1 "$BIN/toit.run" --verify ${TRUSTED[@]+"${TRUSTED[@]}"} --no-certificate "$snap" 2>&1 | grep '^verifier' || true)
  methods=$(sed -E 's/.*, ([0-9]+) methods.*/\1/' <<< "$info")
  bytecodes=$(sed -E 's/.*methods, ([0-9]+) bytecodes.*/\1/' <<< "$info")
  fraction=$(awk -v c="$cert" -v b="$bytecodes" 'BEGIN { if (b > 0) printf "%.0f", 100 * c / b; else print "-" }')
  echo "$name $bytecodes $methods $cert $fraction shipped: $(measure "$snap" --require-certificate) inferred: $(measure "$snap" --no-certificate)"
done
