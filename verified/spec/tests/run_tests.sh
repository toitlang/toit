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

# Runs every program in tests/toit on the C++ VM and on the reference
# interpreter of the spec (64-bit and 32-bit smis) and diffs stdout and the
# exit code.
#
# Usage: tests/run_tests.sh [test-name...]
# Environment: TOIT (default: <repo>/build/host/sdk/bin/toit),
#              OUT  (default: <crate>/target/spec-tests).

set -u

CRATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$CRATE/../.." && pwd)"
TOIT="${TOIT:-$REPO/build/host/sdk/bin/toit}"
OUT="${OUT:-$CRATE/target/spec-tests}"
RUNNER="$CRATE/target/release/toit-spec-run"

mkdir -p "$OUT"
(cd "$CRATE" && cargo build --release --quiet) || exit 1

DUMPER="$OUT/spec_dump.snapshot"
"$TOIT" compile --snapshot -o "$DUMPER" "$REPO/tools/spec_dump.toit" || exit 1

if [ $# -gt 0 ]; then
  TESTS=("$@")
else
  TESTS=()
  for f in "$CRATE"/tests/toit/*.toit; do
    TESTS+=("$(basename "$f" .toit)")
  done
fi

pass=0
fail=0
failed=()
for name in "${TESTS[@]}"; do
  src="$CRATE/tests/toit/$name.toit"
  base="$OUT/$name"
  if ! "$TOIT" compile --snapshot -o "$base.snapshot" "$src" 2> "$base.compile.err"; then
    echo "FAIL $name (compile)"
    fail=$((fail + 1)); failed+=("$name"); continue
  fi
  "$TOIT" run "$base.snapshot" > "$base.vm.out" 2> "$base.vm.err"
  echo "exit $?" >> "$base.vm.out"
  "$TOIT" run "$DUMPER" -- "$base.snapshot" "$base.dump" || { echo "FAIL $name (dump)"; fail=$((fail + 1)); failed+=("$name"); continue; }
  ok=1
  for bits in 64 32; do
    "$RUNNER" --word-bits $bits --stats "$base.dump" > "$base.spec$bits.out" 2> "$base.spec$bits.err"
    echo "exit $?" >> "$base.spec$bits.out"
    # The host VM is 64-bit. Programs whose output depends on the smi size
    # have a hand-checked expectation for 32-bit smis.
    expected="$base.vm.out"
    [ $bits = 32 ] && [ -f "$CRATE/tests/toit/$name.expected32" ] && expected="$CRATE/tests/toit/$name.expected32"
    if ! diff -q "$expected" "$base.spec$bits.out" > /dev/null; then
      ok=0
      echo "--- $name: expected vs spec ($bits-bit) differ:"
      diff "$expected" "$base.spec$bits.out" | head -20
      tail -5 "$base.spec$bits.err"
    fi
  done
  steps=$(grep -o 'steps: [0-9]*, verified steps: [0-9]*' "$base.spec64.err" | head -1)
  if [ $ok = 1 ]; then
    echo "PASS $name ($steps)"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    fail=$((fail + 1)); failed+=("$name")
  fi
done

echo
echo "$pass passed, $fail failed"
if [ $fail -gt 0 ]; then
  echo "failed: ${failed[*]}"
  exit 1
fi
