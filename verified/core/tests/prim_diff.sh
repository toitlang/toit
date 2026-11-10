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

# Differential test of the Rust primitives (verified/core/src/prims)
# against the C++ ones.
#
# Runs tests/fuzz/primitive-diff.toit in format 2 for each seed twice: trusted
# without verification (the core's checked loop, which calls the C++
# primitives) and untrusted (the verified loop, which runs the Rust ports),
# and compares the outputs (a checksum line per
# 10,000 calls). On a difference it reruns the first differing window with
# a trace and prints the first differing call.
#
# Usage: prim_diff.sh [SEEDS [ITERATIONS [JOBS [FIRST-SEED]]]]
#   defaults: 10 seeds, 1,000,000 calls each, 8 jobs, first seed 1.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUN="$REPO/build/host/sdk/lib/toit/bin/toit.run"
DRIVER="$REPO/tests/fuzz/primitive-diff.toit"
SEEDS="${1:-10}"
ITERATIONS="${2:-1000000}"
JOBS="${3:-8}"
FIRST="${4:-1}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/prim-diff.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

run() {  # seed rust iterations [trace-from trace-to]
  local seed="$1" rust="$2"; shift 2
  if [ "$rust" = 1 ]; then
    (cd "$REPO" && env -u TOIT_BYTECODE_FORMAT -u TOIT_VERIFY "$RUN" --untrusted "$DRIVER" "$seed" "$@")
  else
    (cd "$REPO" && env -u TOIT_VERIFY TOIT_BYTECODE_FORMAT=2 "$RUN" "$DRIVER" "$seed" "$@")
  fi
}

one() {  # seed
  local seed="$1"
  run "$seed" 0 "$ITERATIONS" > "$OUT/$seed.cxx" 2>&1; local rc1=$?
  run "$seed" 1 "$ITERATIONS" > "$OUT/$seed.rust" 2>&1; local rc2=$?
  if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && cmp -s "$OUT/$seed.cxx" "$OUT/$seed.rust"; then
    echo "seed $seed: identical ($ITERATIONS calls)"
    return
  fi
  # The last common checkpoint starts the window to trace.
  local window
  window=$(paste -d'|' "$OUT/$seed.cxx" "$OUT/$seed.rust" \
    | awk -F'|' '$1 != $2 { exit } $1 ~ /^checksum / { split($1, a, " "); w = a[2] } END { print w + 0 }')
  run "$seed" 0 "$ITERATIONS" "$window" "$((window + 10000))" 2>&1 | grep -v '^checksum' > "$OUT/$seed.cxx.trace"
  run "$seed" 1 "$ITERATIONS" "$window" "$((window + 10000))" 2>&1 | grep -v '^checksum' > "$OUT/$seed.rust.trace"
  echo "seed $seed: DIFFERENT (exit $rc1 vs $rc2)"
  diff "$OUT/$seed.cxx.trace" "$OUT/$seed.rust.trace" | head -4 | cut -c1-400
}

export -f run one
export REPO RUN DRIVER ITERATIONS OUT
seq "$FIRST" "$((FIRST + SEEDS - 1))" | xargs -P "$JOBS" -I{} bash -c 'one {}' > "$OUT/summary"
cat "$OUT/summary"
failures=$(grep -c ': DIFFERENT' "$OUT/summary")
echo "$((SEEDS - failures))/$SEEDS seeds identical, $((SEEDS * ITERATIONS)) calls per run"
[ "$failures" = 0 ]
