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

# The gate for verified/: run before every merge. See verified/README.md.
#
#   1. Verus on verified/core and verified/spec: 0 errors required.
#   2. Escape-hatch audit against verified/TRUSTED.toml (and a cross-check
#      with `verus --no-cheating`); writes verified/THEOREMS.txt.
#   3. With --tests: layout check, spec differential tests, sandbox ctests.
#
# Usage: verified/check.sh [--tests] [--update-allowlist] [--build DIR]
# Exit code is non-zero on any failure.

set -u -o pipefail

VERIFIED="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$VERIFIED/.." && pwd)"
BUILD_DIR="$REPO/build/host"
RUN_TESTS=0
AUDIT_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --tests) RUN_TESTS=1 ;;
    --update-allowlist) AUDIT_ARGS+=(--update-allowlist) ;;
    --build) shift; BUILD_DIR="$(cd "$1" && pwd)" ;;
    -h|--help) sed -n '/^# The gate/,/^# Exit code/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/verified-check.XXXXXX")"
trap 'rm -rf "$LOGS"' EXIT

FAILURES=()
fail() {
  FAILURES+=("$1")
  echo "FAIL: $1"
}

section() {
  echo
  echo "=== $1"
}

# Crate name, directory, extra Verus arguments. Keep in sync with CRATES in
# verified/tools/trust_audit.py. Commands from verified/core/NOTES.md and
# verified/spec/DESIGN.md.
CRATES=(core spec)
crate_args() {
  case "$1" in
    core) echo "--cfg toit_vcore_hosted" ;;
    spec) echo "" ;;
  esac
}

# Runs Verus on one crate. Direct `verus` is preferred (the crates' documented
# command); `cargo verus verify` is the fallback when only cargo-verus exists.
verify_crate() {
  local name="$1"
  local dir="$VERIFIED/$name"
  local log="$LOGS/$name.log"
  local args
  read -r -a args <<< "$(crate_args "$name")"
  local start end rc
  start=$(date +%s.%N)
  if command -v verus > /dev/null; then
    (cd "$dir" && verus --crate-type=lib "${args[@]}" src/lib.rs --time) > "$log" 2>&1
    rc=$?
  elif command -v cargo-verus > /dev/null; then
    (cd "$dir" && cargo verus verify -- --time) > "$log" 2>&1
    rc=$?
  else
    fail "$name: neither verus nor cargo-verus is installed"
    return
  fi
  end=$(date +%s.%N)
  local wall
  wall=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", e - s }')
  local result
  result=$(grep -E '^verification results:: ' "$log" | tail -1)
  local verified errors smt total
  verified=$(sed -nE 's/^verification results:: ([0-9]+) verified, ([0-9]+) errors.*/\1/p' <<< "$result")
  errors=$(sed -nE 's/^verification results:: ([0-9]+) verified, ([0-9]+) errors.*/\2/p' <<< "$result")
  total=$(grep -E '^total-time:' "$log" | tail -1 | awk '{print $2}')
  smt=$(grep -E 'total smt-time:' "$log" | tail -1 | awk '{print $3}')
  printf '%-5s %5s verified, %s errors; verus total %s ms (SMT %s ms), wall %s s\n' \
    "$name" "${verified:-?}" "${errors:-?}" "${total:-?}" "${smt:-?}" "$wall"
  if [ "$rc" -ne 0 ] || [ -z "$result" ] || [ "${errors:-1}" != "0" ]; then
    grep -E '^(error|warning: unused)|^ *--> ' "$log" | head -40
    fail "$name: Verus did not report 0 errors (exit code $rc; full log follows)"
    cat "$log"
  fi
  # Verus' own detector, for the audit's cross-check. Exits non-zero whenever
  # the crate has any escape hatch; only the reported locations matter.
  if command -v verus > /dev/null; then
    (cd "$dir" && verus --crate-type=lib "${args[@]}" src/lib.rs --no-cheating --no-verify) \
      > "$LOGS/$name.nocheat.log" 2>&1
    AUDIT_ARGS+=(--no-cheating-log "$name=$LOGS/$name.nocheat.log")
  fi
}

section "Verus ($(verus --version 2>/dev/null | sed -n 's/^ *Version: //p'))"
for c in "${CRATES[@]}"; do
  verify_crate "$c"
done

section "Escape-hatch audit"
if ! python3 -I "$VERIFIED/tools/trust_audit.py" --root "$VERIFIED" "${AUDIT_ARGS[@]}"; then
  fail "escape-hatch audit (see above)"
fi

if [ "$RUN_TESTS" = 1 ]; then
  section "Layout check"
  if [ -f "$BUILD_DIR/build.ninja" ]; then
    if ninja -C "$BUILD_DIR" toit_verified_core_layout_check > "$LOGS/layout.log" 2>&1 \
        && ctest --test-dir "$BUILD_DIR" -R '^verified_core_layout$' --output-on-failure; then
      echo "layout check passed"
    else
      tail -40 "$LOGS/layout.log"
      fail "layout check"
    fi
  else
    echo "SKIP: no build in $BUILD_DIR (run tools/worktree-setup.sh or make sdk)"
  fi

  section "Spec differential tests (verified/spec/tests/run_tests.sh)"
  if [ -x "$BUILD_DIR/sdk/bin/toit" ]; then
    if ! TOIT="$BUILD_DIR/sdk/bin/toit" "$VERIFIED/spec/tests/run_tests.sh"; then
      fail "verified/spec/tests/run_tests.sh"
    fi
  else
    echo "SKIP: $BUILD_DIR/sdk/bin/toit missing (make sdk)"
  fi

  section "Verifier in the VM (verified/vmverify): unit tests, differential sample"
  if (cd "$VERIFIED/vmverify" && cargo test --release --quiet > "$LOGS/vmverify.log" 2>&1); then
    grep -E '^test result' "$LOGS/vmverify.log" | head -3
  else
    tail -40 "$LOGS/vmverify.log"
    fail "vmverify unit tests"
  fi
  if [ -x "$BUILD_DIR/sdk/bin/toit" ]; then
    # The full run (every suite program) is
    # `verified/vmverify/tests/differential.py`; a sample keeps the gate fast.
    if ! TOIT="$BUILD_DIR/sdk/bin/toit" python3 "$VERIFIED/vmverify/tests/differential.py" \
        --filter tests/class-id-test --filter tests/lambda-test --filter tests/string-test.toit \
        --filter tests/exception-test --out "$LOGS/differential"; then
      fail "vmverify differential sample"
    fi
    # The fuzz reproducers: no verifier panic, rejections where required.
    if ! bash "$VERIFIED/vmverify/tests/findings.sh" "$BUILD_DIR/sdk/lib/toit/bin/toit.run" > "$LOGS/findings.log" 2>&1; then
      cat "$LOGS/findings.log"
      fail "vmverify fuzz findings"
    else
      tail -1 "$LOGS/findings.log"
    fi
  else
    echo "SKIP: $BUILD_DIR/sdk/bin/toit missing (make sdk)"
  fi

  section "Sandbox ctests"
  if [ -f "$BUILD_DIR/CTestTestfile.cmake" ] && [ -x "$BUILD_DIR/sdk/bin/toit" ]; then
    if ! ctest --test-dir "$BUILD_DIR" -R '^tests/sandbox/' -j "$(nproc)" --output-on-failure; then
      fail "sandbox ctests"
    fi
  else
    echo "SKIP: no configured build with an SDK in $BUILD_DIR"
  fi
fi

section "Summary"
if [ ${#FAILURES[@]} -ne 0 ]; then
  echo "verified/check.sh FAILED:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
echo "verified/check.sh passed."
