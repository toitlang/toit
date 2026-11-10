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

# Measures the Rust primitives against the C++ bridge.
#
# For each benchmark of verified/core/tests/prim_bench.toit (and each
# PROGRAM given) runs it untrusted (format 2; the programs trusted with
# TOIT_BYTECODE_FORMAT=2 TOIT_VERIFY=1) under callgrind, counting only the
# instructions inside `toit_v2_run` (the format-2 run loop and everything
# it calls: primitives, GC), with the C++ primitives and with
# TOIT_V2_RUST_PRIMITIVES=1; then the wall times (best of 5) without
# callgrind.
#
# Usage: prim_bench.sh [PROGRAM...]

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUN="$REPO/build/host/sdk/lib/toit/bin/toit.run"
BENCH="$REPO/verified/core/tests/prim_bench.toit"
NAMES="${PRIM_BENCH_NAMES:-map-string-keys string-concat-slice list-add byte-array large-int float
       string-compare-hash call-smi-add call-string-length call-array-at
       call-float-add call-blob-equals}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/prim-bench.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

ir() {  # rust command...
  local rust="$1"; shift
  rm -f "$OUT"/cg.*
  (cd "$REPO" && env -u TOIT_BYTECODE_FORMAT TOIT_V2_RUST_PRIMITIVES="$rust" $EXTRA \
    valgrind --tool=callgrind --toggle-collect=toit_v2_run --callgrind-out-file="$OUT/cg.%p" "$@" \
    > /dev/null 2>&1)
  cat "$OUT"/cg.* | awk '/^summary:/ { s += $2 } END { print s + 0 }'
}

row() {  # name command...
  local name="$1"; shift
  local a b
  a=$(ir 0 "$@")
  b=$(ir 1 "$@")
  awk -v n="$name" -v a="$a" -v b="$b" 'BEGIN { printf "| %s | %d | %d | %.3f |\n", n, a, b, b / a }'
}

echo "| Benchmark | C++ Ir | Rust Ir | ratio |"
echo "|---|---|---|---|"
EXTRA=""
for name in $NAMES; do
  row "$name" "$RUN" --untrusted "$BENCH" "$name"
done
EXTRA="TOIT_BYTECODE_FORMAT=2 TOIT_VERIFY=1"
for prog in "$@"; do
  row "$(basename "$prog")" "$RUN" "$prog"
done
echo
for rust in 0 1; do
  if [ "$rust" = 1 ]; then echo "Rust wall (best of 5):"; else echo "C++ wall (best of 5):"; fi
  (cd "$REPO" && env -u TOIT_BYTECODE_FORMAT TOIT_V2_RUST_PRIMITIVES="$rust" "$RUN" --untrusted "$BENCH")
done
