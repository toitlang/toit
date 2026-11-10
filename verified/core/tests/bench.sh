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

# Wall-time benchmark of the core (format 2) against the C++ interpreter
# (format 1): richards, deltablue and pystone of the benchmarks repository,
# minimum of RUNS runs of the time per iteration the benchmark prints.
#
# Usage: verified/core/tests/bench.sh [BUILD_DIR] [RUNS]
#   BUILD_DIR defaults to build/host; BENCHMARKS (environment) to
#   /home/flo/work/benchmarks/toit. Snapshots go to BUILD_DIR/vcore-bench.

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD="${1:-$REPO/build/host}"
RUNS="${2:-5}"
BENCHMARKS="${BENCHMARKS:-/home/flo/work/benchmarks/toit}"
BIN="$BUILD/sdk/lib/toit/bin"
OUT="$BUILD/vcore-bench"
mkdir -p "$OUT"

printf '%-10s %10s %10s %7s\n' benchmark "f1 ms" "f2 ms" ratio
for b in richards deltablue pystone; do
  "$BIN/toit.compile" -w "$OUT/$b-f1.snap" "$BENCHMARKS/$b.toit"
  TOIT_BYTECODE_FORMAT=2 "$BIN/toit.compile" -w "$OUT/$b-f2.snap" "$BENCHMARKS/$b.toit"
  best=()
  for f in f1 f2; do
    min=""
    for _ in $(seq "$RUNS"); do
      # The harness prints "<Name> - time per iteration: <t> ms (...)".
      t=$("$BIN/toit.run" "$OUT/$b-$f.snap" | sed -nE 's/.*time per iteration: ([0-9.]+) ms.*/\1/p' | tail -1)
      if [ -z "$min" ] || awk -v a="$t" -v b="$min" 'BEGIN { exit !(a < b) }'; then min="$t"; fi
    done
    best+=("$min")
  done
  awk -v b="$b" -v x="${best[0]}" -v y="${best[1]}" \
    'BEGIN { printf "%-10s %10.2f %10.2f %7.2f\n", b, x, y, y / x }'
done
