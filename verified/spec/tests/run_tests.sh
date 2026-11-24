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
# exit code. Each program also runs in the revised bytecode format (format
# 2, compiled with -Xbytecode_format=2) on the interpreter, against the same
# C++ VM output of the format-1 build.
#
# Usage: tests/run_tests.sh [test-name...]
# Environment: TOIT (default: <repo>/build/host/sdk/bin/toit),
#              OUT  (default: <crate>/target/spec-tests).

set -u

CRATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$CRATE/../.." && pwd)"
TOIT="${TOIT:-$REPO/build/host/sdk/bin/toit}"
TOIT_COMPILE="$(dirname "$(dirname "$TOIT")")/lib/toit/bin/toit.compile"
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

# One program; prints its report and returns 1 when it failed. The programs
# are independent (each writes only $OUT/<name>.*) and run in parallel.
run_test() {
  local name="$1" src base ok bits expected steps steps2
  src="$CRATE/tests/toit/$name.toit"
  base="$OUT/$name"
  if ! "$TOIT" compile --snapshot -o "$base.snapshot" "$src" 2> "$base.compile.err"; then
    echo "FAIL $name (compile)"
    return 1
  fi
  "$TOIT" run "$base.snapshot" > "$base.vm.out" 2> "$base.vm.err"
  echo "exit $?" >> "$base.vm.out"
  "$TOIT" run "$DUMPER" -- "$base.snapshot" "$base.dump" || { echo "FAIL $name (dump)"; return 1; }
  ok=1
  for bits in 64 32; do
    "$RUNNER" --word-bits $bits --max-steps 100000000 --stats "$base.dump" > "$base.spec$bits.out" 2> "$base.spec$bits.err"
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
  # The revised format.
  if ! "$TOIT_COMPILE" -Xbytecode_format=2 -w "$base.v2.snapshot" "$src" 2> "$base.v2.compile.err"; then
    ok=0
    echo "--- $name: format-2 compilation failed"
  elif ! "$TOIT" run "$DUMPER" -- "$base.v2.snapshot" "$base.v2.dump"; then
    ok=0
    echo "--- $name: format-2 dump failed"
  else
    for bits in 64 32; do
      "$RUNNER" --word-bits $bits --max-steps 100000000 --stats "$base.v2.dump" > "$base.v2spec$bits.out" 2> "$base.v2spec$bits.err"
      echo "exit $?" >> "$base.v2spec$bits.out"
      expected="$base.vm.out"
      [ $bits = 32 ] && [ -f "$CRATE/tests/toit/$name.expected32" ] && expected="$CRATE/tests/toit/$name.expected32"
      if ! diff -q "$expected" "$base.v2spec$bits.out" > /dev/null; then
        ok=0
        echo "--- $name: expected vs format-2 spec ($bits-bit) differ:"
        diff "$expected" "$base.v2spec$bits.out" | head -20
        tail -5 "$base.v2spec$bits.err"
      fi
    done
  fi
  # The unverified mirror alone must agree with the verified+unverified mix.
  "$RUNNER" --no-verified --max-steps 100000000 "$base.dump" > "$base.specu.out" 2> "$base.specu.err"
  echo "exit $?" >> "$base.specu.out"
  if ! diff -q "$base.spec64.out" "$base.specu.out" > /dev/null; then
    ok=0
    echo "--- $name: verified and unverified step differ"
  fi
  steps=$(grep -o 'steps: [0-9]*, verified steps: [0-9]*' "$base.spec64.err" | head -1)
  steps2=$(grep -o 'steps: [0-9]*, verified steps: [0-9]*' "$base.v2spec64.err" | head -1)
  if [ $ok = 1 ]; then
    echo "PASS $name (format 1: $steps; format 2: $steps2)"
    return 0
  fi
  echo "FAIL $name"
  return 1
}

# At most SPEC_TEST_JOBS programs at once (default: the core count); the
# reports are printed in order.
MAXJOBS="${SPEC_TEST_JOBS:-$(nproc)}"
trap 'trap - TERM INT HUP; kill -TERM $(jobs -p) 2> /dev/null; wait; exit 143' TERM INT HUP
for name in "${TESTS[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do wait -n; done
  rm -f "$OUT/$name.status"
  { run_test "$name"; echo $? > "$OUT/$name.status"; } > "$OUT/$name.report" 2>&1 &
done
wait

pass=0
fail=0
failed=()
for name in "${TESTS[@]}"; do
  cat "$OUT/$name.report"
  if [ "$(cat "$OUT/$name.status" 2> /dev/null)" = 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed+=("$name")
  fi
done

echo
echo "$pass passed, $fail failed"
if [ $fail -gt 0 ]; then
  echo "failed: ${failed[*]}"
  exit 1
fi
