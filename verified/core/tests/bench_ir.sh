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

# Instruction counts (callgrind Ir, whole run, startup about 6 M) of the
# benchmarks in format 1 and format 2: independent of the machine's load,
# unlike bench.sh. Uses the snapshots bench.sh writes.
#
# Usage: verified/core/tests/bench_ir.sh [BUILD_DIR] [TOIT_RUN...]
#   With several toit.run binaries (e.g. a baseline copy), each is measured
#   on the format-2 snapshots; format 1 is measured with the first.

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD="${1:-$REPO/build/host}"
shift || true
RUNS=("$@")
[ ${#RUNS[@]} -eq 0 ] && RUNS=("$BUILD/sdk/lib/toit/bin/toit.run")
OUT="$BUILD/vcore-bench"

ir() {
  valgrind --tool=callgrind --callgrind-out-file=/dev/null "$1" "$2" 2>&1 \
    | sed -nE 's/.*I +refs: +([0-9,]+).*/\1/p' | tr -d ,
}

for b in richards deltablue pystone; do
  line="$b f1 $(ir "${RUNS[0]}" "$OUT/$b-f1.snap")"
  for r in "${RUNS[@]}"; do
    line="$line | $(basename "$r") f2 $(ir "$r" "$OUT/$b-f2.snap")"
  done
  echo "$line" &
done
wait
