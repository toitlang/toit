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
#   1. Verus on verified/core and verified/spec: 0 errors required, for
#      64-bit words (the host) and for 32-bit words (i686 target); the core
#      in both configurations of its run loop (whole, and split with the
#      `split-loop` feature).
#   2. Escape-hatch audit against verified/TRUSTED.toml (and a cross-check
#      with `verus --no-cheating`); writes verified/THEOREMS.txt. The leaf
#      contracts of verified/CONTRACTS.toml against both of their sides.
#      No Python in the repository (verified/tools/no_python_check.sh).
#   3. With --tests: the audit's and the no-Python check's self-tests,
#      layout check, the VeriFast proofs of the residual C++
#      (verified/cxx/annotated), spec differential tests, the device
#      library's no-panic check, sandbox ctests, and (optional, when a
#      second build exists) the red-team batteries. The residual C++ matrix
#      runs its fast tier.
#   4. With --slow (implies --tests): also the slow tier of the residual
#      C++ matrix (verified/cxx/annotated/run.sh --slow: the long
#      model-checker jobs; hours, memory-capped).
#
# The checks are named sections, run in order. `--list` prints the names
# of the sections the given flags select; `--only NAME[,NAME...]` runs just
# those (verified/gate.sh runs the sections in parallel this way, each in
# its own process). Sections exchange files through the log directory: the
# audit reads the `verus --no-cheating` logs of section `verus`, so with
# `--only audit` give `--logs DIR` of a run that did `verus`.
#
# Usage: verified/check.sh [--tests] [--slow] [--update-allowlist] [--build DIR]
#                          [--list] [--only NAME[,NAME...]] [--logs DIR]
# Exit code is non-zero on any failure. With --only, it is 3 when no
# section failed but one was skipped (a tool or build it needs is missing).

set -u -o pipefail

VERIFIED="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$VERIFIED/.." && pwd)"
BUILD_DIR="$REPO/build/host"
RUN_TESTS=0
RUN_SLOW=0
AUDIT_ARGS=()
LIST=0
ONLY=""
LOGS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tests) RUN_TESTS=1 ;;
    --slow) RUN_TESTS=1; RUN_SLOW=1 ;;
    --update-allowlist) AUDIT_ARGS+=(--update-allowlist) ;;
    --build) shift; BUILD_DIR="$(cd "$1" && pwd)" ;;
    --list) LIST=1 ;;
    --only) shift; ONLY="$1" ;;
    --logs) shift; mkdir -p "$1" && LOGS="$(cd "$1" && pwd)" ;;
    -h|--help) sed -n '/^# The gate/,/^# section failed/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# The sections, in the order they run. Those after TEST_SECTIONS need
# --tests, `cxx-slow` needs --slow.
BASE_SECTIONS=(verus verus32 audit contracts layout-table no-python)
TEST_SECTIONS=(ieee audit-test no-python-self-test layout-check cxx cxx-slow spec-tests vmverify
               nopanic ec618-nopanic ec618-codegen sandbox-ctests
               redteam3-heap redteam3-asm
               redteam4-A redteam4-A-cert redteam4-B redteam4-C redteam4-D redteam4-E redteam4-F)
selected_sections() {
  printf '%s\n' "${BASE_SECTIONS[@]}"
  if [ "$RUN_TESTS" = 1 ]; then
    local s
    for s in "${TEST_SECTIONS[@]}"; do
      [ "$s" = cxx-slow ] && [ "$RUN_SLOW" != 1 ] && continue
      echo "$s"
    done
  fi
}
all_sections() {
  printf '%s\n' "${BASE_SECTIONS[@]}" "${TEST_SECTIONS[@]}"
}

if [ "$LIST" = 1 ]; then
  selected_sections
  exit 0
fi

SECTIONS=()
if [ -n "$ONLY" ]; then
  IFS=, read -r -a wanted <<< "$ONLY"
  for w in "${wanted[@]}"; do
    if ! all_sections | grep -qxF -- "$w"; then
      echo "Unknown section: $w (verified/check.sh --list --slow lists them)" >&2
      exit 2
    fi
  done
  # In the order of the table, whatever the order of the arguments.
  while read -r s; do
    for w in "${wanted[@]}"; do
      [ "$w" = "$s" ] && { SECTIONS+=("$s"); break; }
    done
  done < <(all_sections)
else
  mapfile -t SECTIONS < <(selected_sections)
fi

if [ -z "$LOGS" ]; then
  LOGS="$(mktemp -d "${TMPDIR:-/tmp}/verified-check.XXXXXX")"
  trap 'rm -rf "$LOGS"' EXIT
fi

FAILURES=()
SKIPPED=()
RESULTS=()
SECTION_SKIPPED=0
fail() {
  FAILURES+=("$1")
  echo "FAIL: $1"
}
# A check that could not run here (a tool or build it needs is missing).
skip() {
  echo "SKIP: $1"
  SECTION_SKIPPED=1
}

section() {
  echo
  echo "=== $1"
}

# Commands that write into the build directory (ninja, cmake) take this
# lock, so that sections running at the same time (verified/gate.sh) and
# the gate's own build steps do not run two of them there at once.
build_locked() {
  flock "$BUILD_DIR/.check-build.lock" "$@"
}

# Crate name, directory, extra Verus arguments. Keep in sync with CRATES in
# verified/tools/trust_audit.toit. Commands from verified/core/NOTES.md and
# verified/spec/DESIGN.md. The spec crate is verified first and exports its
# Verus metadata and an rlib; the core imports both (it is proven against
# the spec's definitions, verified/core/DESIGN.md section 9).
# The core is verified with its `checked-loop` and `layout-tables` features
# (the defaults; devices build without them, which only leaves code out:
# verified/core/Cargo.toml) and `preempt-a-lot` (debug VM builds only).
# `core-split` is the core once more with `split-loop` (the run loop split
# into a hot part and `step_cold`, Kconfig TOIT_VERIFIED_CORE_SPLIT_LOOP):
# the two configurations of the loop compile different code.
CRATES=(spec core core-split)
crate_args() {
  case "$1" in
    core) echo "--crate-name toit_verified_core --cfg toit_vcore_hosted --cfg feature=\"checked-loop\" --cfg feature=\"layout-tables\" --cfg feature=\"preempt-a-lot\" --extern toit_spec=$LOGS/libtoit_spec.rlib --import toit_spec=$LOGS/toit_spec.vir" ;;
    core-split) echo "$(crate_args core) --cfg feature=\"split-loop\"" ;;
    spec) echo "--crate-name toit_spec" ;;
  esac
}
# Arguments of the verifying run only (not of the --no-cheating cross-check).
crate_verify_args() {
  case "$1" in
    core|core-split) echo "" ;;
    spec) echo "--export $LOGS/toit_spec.vir --compile -o $LOGS/libtoit_spec.rlib" ;;
  esac
}
# The crate's directory (core-split: verified/core).
crate_dir() {
  echo "$VERIFIED/${1%-split}"
}

# Runs Verus on one crate. Direct `verus` is preferred (the crates' documented
# command); `cargo verus verify` is the fallback when only cargo-verus exists.
verify_crate() {
  local name="$1"
  local dir
  dir="$(crate_dir "$name")"
  local log="$LOGS/$name.log"
  local args vargs
  read -r -a args <<< "$(crate_args "$name")"
  read -r -a vargs <<< "$(crate_verify_args "$name")"
  local cargo_args=()
  [ "$name" = core-split ] && cargo_args=(--features split-loop)
  local start end rc
  start=$(date +%s.%N)
  if command -v verus > /dev/null; then
    (cd "$dir" && verus --crate-type=lib "${args[@]}" "${vargs[@]}" src/lib.rs --time) > "$log" 2>&1
    rc=$?
  elif command -v cargo-verus > /dev/null; then
    (cd "$dir" && cargo verus verify "${cargo_args[@]}" -- --time) > "$log" 2>&1
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
  fi
}

sec_verus() {
  section "Verus ($(verus --version 2>/dev/null | sed -n 's/^ *Version: //p'))"
  local c
  for c in "${CRATES[@]}"; do
    verify_crate "$c"
  done
}

# The same crates for 32-bit words: Verus with `--target
# i686-unknown-linux-gnu` and its support libraries built for that target
# (verified/tools/verus_target.sh), so that `usize` is 32 bits wide in every
# proof (the core's `global size_of usize` is per target_pointer_width; the
# crates' code is the same except for the cfg'd constants of layout.rs).
# This is the proof for the 32-bit host and the riscv32 devices.
verify_crate_word32() {
  local name="$1"
  local dir
  dir="$(crate_dir "$name")"
  local log="$LOGS/$name.word32.log"
  local args=()
  case "$name" in
    spec) args=(--crate-name toit_spec --export "$LOGS/w32/toit_spec.vir" --compile -o "$LOGS/w32/libtoit_spec.rlib") ;;
    core|core-split)
      args=(--crate-name toit_verified_core --cfg toit_vcore_hosted --cfg 'feature="checked-loop"' --cfg 'feature="layout-tables"' --cfg 'feature="preempt-a-lot"'
            --extern "toit_spec=$LOGS/w32/libtoit_spec.rlib" --import "toit_spec=$LOGS/w32/toit_spec.vir")
      [ "$name" = core-split ] && args+=(--cfg 'feature="split-loop"') ;;
  esac
  local start end rc
  start=$(date +%s.%N)
  (cd "$dir" && "$VERUS32" --crate-type=lib --target "$WORD32_TARGET" "${args[@]}" src/lib.rs --time) > "$log" 2>&1
  rc=$?
  end=$(date +%s.%N)
  local result verified errors total smt wall
  result=$(grep -E '^verification results:: ' "$log" | tail -1)
  verified=$(sed -nE 's/^verification results:: ([0-9]+) verified, ([0-9]+) errors.*/\1/p' <<< "$result")
  errors=$(sed -nE 's/^verification results:: ([0-9]+) verified, ([0-9]+) errors.*/\2/p' <<< "$result")
  total=$(grep -E '^total-time:' "$log" | tail -1 | awk '{print $2}')
  smt=$(grep -E 'total smt-time:' "$log" | tail -1 | awk '{print $3}')
  wall=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", e - s }')
  printf '%-5s %5s verified, %s errors; verus total %s ms (SMT %s ms), wall %s s (32-bit words)\n' \
    "$name" "${verified:-?}" "${errors:-?}" "${total:-?}" "${smt:-?}" "$wall"
  if [ "$rc" -ne 0 ] || [ -z "$result" ] || [ "${errors:-1}" != "0" ]; then
    grep -E '^(error|warning: unused)|^ *--> ' "$log" | head -40
    fail "$name (32-bit words): Verus did not report 0 errors (exit code $rc; full log follows)"
    cat "$log"
  fi
}

WORD32_TARGET=i686-unknown-linux-gnu
sec_verus32() {
  section "Verus, 32-bit words ($WORD32_TARGET)"
  mkdir -p "$LOGS/w32"
  local c
  # verus_target.sh builds into the checkout's build directory; one at a
  # time (two gate runs of one checkout).
  mkdir -p "$REPO/build"
  if VERUS32="$(flock "$REPO/build/.verus-target.lock" \
      "$VERIFIED/tools/verus_target.sh" "$WORD32_TARGET" "$REPO/build/verus-$WORD32_TARGET")"; then
    for c in "${CRATES[@]}"; do
      verify_crate_word32 "$c"
    done
  else
    fail "32-bit words: cannot set up Verus for $WORD32_TARGET (verified/tools/verus_target.sh; rustup target add $WORD32_TARGET)"
  fi
}

# The tools in verified/tools are Toit programs: they need a toit executable
# (the build's SDK, else one on the PATH) and the packages of the
# verified/tools project (installed by `make download-packages`, or here).
TOIT_BIN="$BUILD_DIR/sdk/bin/toit"
[ -x "$TOIT_BIN" ] || TOIT_BIN="$(command -v toit || true)"
tools_ready() {
  if [ -z "$TOIT_BIN" ]; then
    echo "no toit executable: run 'make sdk' or put toit on the PATH"
    return 1
  fi
  # One installation at a time (sections running in parallel).
  mkdir -p "$REPO/build"
  (
    flock 9
    if [ ! -f "$VERIFIED/tools/.packages/contents.json" ] \
        || [ "$VERIFIED/tools/package.lock" -nt "$VERIFIED/tools/.packages/contents.json" ]; then
      "$TOIT_BIN" pkg install --project-root "$VERIFIED/tools" || exit 1
    fi
  ) 9> "$REPO/build/.verified-tools.lock"
}

sec_audit() {
  section "Escape-hatch audit"
  # The cross-check with Verus' detector: the `verus --no-cheating` logs
  # section `verus` wrote (core-split's under the crate name `core` too).
  local args=("${AUDIT_ARGS[@]}") c
  if command -v verus > /dev/null; then
    for c in "${CRATES[@]}"; do
      if [ ! -f "$LOGS/$c.nocheat.log" ]; then
        fail "escape-hatch audit: no verus --no-cheating log of $c in $LOGS (run section verus first, with the same --logs)"
        return
      fi
      args+=(--verus-no-cheating-log "${c%-split}=$LOGS/$c.nocheat.log")
    done
  fi
  if ! tools_ready; then
    fail "escape-hatch audit: cannot run verified/tools/trust_audit.toit"
  elif ! "$TOIT_BIN" run "$VERIFIED/tools/trust_audit.toit" -- --root "$VERIFIED" "${args[@]}"; then
    fail "escape-hatch audit (see above)"
  fi
}

sec_contracts() {
  section "Leaf contracts, Verus and VeriFast (verified/CONTRACTS.toml)"
  if ! tools_ready; then
    fail "contract table: cannot run verified/tools/contract_check.toit"
  elif ! "$TOIT_BIN" run "$VERIFIED/tools/contract_check.toit" -- --root "$VERIFIED"; then
    fail "contract table: a Verus or VeriFast contract differs from verified/CONTRACTS.toml (see above)"
  fi
}

sec_layout_table() {
  section "Layout facts, Verus and VeriFast (verified/LAYOUT.toml)"
  # Against layout.rs here; against the C++ and the VeriFast model by the
  # generated static assertions, compiled in the VeriFast section.
  if ! tools_ready; then
    fail "layout table: cannot run verified/tools/layout_table.toit"
  elif ! "$TOIT_BIN" run "$VERIFIED/tools/layout_table.toit" -- --check --root "$VERIFIED"; then
    fail "layout table: verified/LAYOUT.toml differs from layout.rs or its generated checks (see above)"
  fi
}

sec_no_python() {
  section "No Python in the repository (verified/tools/no_python_check.sh)"
  # The tooling is Toit, shell, CMake, or Rust inside verified/. Its self-test
  # (a tracked .py or .pyc, scripts that call python) runs with --tests.
  if ! "$VERIFIED/tools/no_python_check.sh" "$REPO"; then
    fail "Python in the repository (see above)"
  fi
}

sec_ieee() {
  section "IEEE binary64 specification checks"
  local z3_bin="${VERUS_Z3_PATH:-$(command -v z3)}" query result
  if [ -z "$z3_bin" ] && command -v verus >/dev/null; then
    z3_bin="$(dirname "$(realpath "$(command -v verus)")")/z3"
  fi
  for query in "$VERIFIED"/spec/tests/binary64-*.smt2; do
    if result=$("$z3_bin" "$query") && [ "$result" = unsat ]; then
      echo "$(basename "$query") passed"
    else
      fail "IEEE check $query with Z3 ($z3_bin): $result"
    fi
  done
}

sec_audit_test() {
  section "Escape-hatch audit regression test (verified/tools/tests/trust_audit_test.sh)"
  if ! tools_ready || ! TOIT="$TOIT_BIN" "$VERIFIED/tools/tests/trust_audit_test.sh"; then
    fail "escape-hatch audit regression test"
  fi
}

sec_no_python_self_test() {
  section "No-Python check self-test (verified/tools/no_python_check.sh --self-test)"
  if ! "$VERIFIED/tools/no_python_check.sh" --self-test; then
    fail "no-Python check self-test"
  fi
}

sec_layout_check() {
  section "Layout check"
  if [ -f "$BUILD_DIR/build.ninja" ]; then
    if build_locked ninja -C "$BUILD_DIR" toit_verified_core_layout_check > "$LOGS/layout.log" 2>&1 \
        && ctest --test-dir "$BUILD_DIR" -R '^verified_core_layout$' --output-on-failure; then
      echo "layout check passed"
    else
      tail -40 "$LOGS/layout.log"
      fail "layout check"
    fi
  else
    skip "no build in $BUILD_DIR (run tools/worktree-setup.sh or make sdk)"
  fi
}

sec_cxx() {
  section "VeriFast proofs of the residual C++ (verified/cxx/annotated/run.sh)"
  # The renderings must match the sources (drift fails), the constants the
  # headers, and every proof and reverted-bug self-test its verdict. Skipped
  # (exit status 3) when VeriFast is not installed.
  if ! tools_ready; then
    fail "VeriFast proofs: cannot run verified/tools/cxx_render.toit"
    return
  fi
  # run.sh's stderr stays on the terminal: a job that waits for
  # model-checker memory (or the run for another run of this checkout)
  # says so there while it waits.
  TOIT="$TOIT_BIN" "$VERIFIED/cxx/annotated/run.sh" > "$LOGS/verifast.log"
  local vf_status=$?
  if [ $vf_status -eq 3 ]; then
    grep '^SKIP' "$LOGS/verifast.log"
    SECTION_SKIPPED=1
  elif [ $vf_status -eq 4 ]; then
    grep '^NOVERDICT' "$LOGS/verifast.log" | head -40
    fail "VeriFast matrix of the residual C++: a model-checker job gave no verdict (out of time or memory)"
  elif [ $vf_status -ne 0 ]; then
    grep -v '^ok' "$LOGS/verifast.log" | head -40
    fail "VeriFast proofs of the residual C++ (a proof failed or a rendering drifted)"
  else
    echo "$(grep -c '^ok' "$LOGS/verifast.log") checks passed ($(tail -1 "$LOGS/verifast.log"))"
  fi
}

sec_cxx_slow() {
  section "The slow tier of the residual C++'s model-checker jobs (run.sh --slow)"
  # Hours; memory-capped jobs, see the README's slow-tier table.
  if ! tools_ready; then
    fail "slow tier: cannot run verified/tools/cxx_render.toit"
    return
  fi
  TOIT="$TOIT_BIN" "$VERIFIED/cxx/annotated/run.sh" --slow > "$LOGS/slow.log"
  local slow_status=$?
  grep -v '^ok' "$LOGS/slow.log" | head -60
  if [ $slow_status -eq 3 ]; then
    SECTION_SKIPPED=1
  elif [ $slow_status -eq 4 ]; then
    fail "slow tier: no verdict for some jobs (out of time or memory; nothing refuted)"
  elif [ $slow_status -ne 0 ]; then
    fail "slow tier: a model-checker job failed"
  else
    echo "$(grep -c '^ok' "$LOGS/slow.log") slow-tier jobs passed"
  fi
}

sec_spec_tests() {
  section "Spec differential tests (verified/spec/tests/run_tests.sh)"
  if [ -x "$BUILD_DIR/sdk/bin/toit" ]; then
    if ! TOIT="$BUILD_DIR/sdk/bin/toit" "$VERIFIED/spec/tests/run_tests.sh"; then
      fail "verified/spec/tests/run_tests.sh"
    fi
  else
    skip "$BUILD_DIR/sdk/bin/toit missing (make sdk)"
  fi
}

sec_vmverify() {
  section "Verifier in the VM (verified/vmverify): unit tests, differential sample"
  if (cd "$VERIFIED/vmverify" && cargo test --release --quiet > "$LOGS/vmverify.log" 2>&1); then
    grep -E '^test result' "$LOGS/vmverify.log" | head -3
  else
    tail -40 "$LOGS/vmverify.log"
    fail "vmverify unit tests"
  fi
  if [ -x "$BUILD_DIR/sdk/bin/toit" ]; then
    # The full run (every suite program) is
    # `verified/tools/vmverify_differential.toit`; a sample keeps the gate
    # fast.
    if ! TOIT="$BUILD_DIR/sdk/bin/toit" "$BUILD_DIR/sdk/bin/toit" run \
        "$VERIFIED/tools/vmverify_differential.toit" -- \
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
    skip "$BUILD_DIR/sdk/bin/toit missing (make sdk)"
  fi
}

sec_nopanic() {
  section "No panic paths in the device library (verified/vmverify/tests/nopanic_check.sh)"
  if command -v riscv32-esp-elf-gcc > /dev/null \
      || ls "$HOME"/.espressif/tools/riscv32-esp-elf/esp-1[0-9]*/riscv32-esp-elf/bin/riscv32-esp-elf-gcc > /dev/null 2>&1; then
    if ! "$VERIFIED/vmverify/tests/nopanic_check.sh" > "$LOGS/nopanic.log" 2>&1; then
      cat "$LOGS/nopanic.log"
      fail "device library links panic machinery (nopanic_check.sh)"
    else
      grep -E '^no panic paths' "$LOGS/nopanic.log"
    fi
  else
    skip "no riscv32-esp-elf-gcc (ESP-IDF toolchain)"
  fi
}

# EC618 (thumbv7m): the Rust target and an arm-none-eabi-gcc.
ec618_tools() {
  rustup target list --installed 2> /dev/null | grep -q '^thumbv7m-none-eabi$' \
    && { [ -x "${EC618_GCC_PATH:-/nonexistent}/bin/arm-none-eabi-gcc" ] \
         || ls "$HOME"/.xmake/packages/g/gnu_rm/*/*/bin/arm-none-eabi-gcc > /dev/null 2>&1 \
         || command -v arm-none-eabi-gcc > /dev/null; }
}

sec_ec618_nopanic() {
  section "EC618 (thumbv7m): no panic paths (nopanic_check.sh)"
  if ! ec618_tools; then
    skip "no thumbv7m-none-eabi Rust target or no arm-none-eabi-gcc"
  elif ! NOPANIC_ARCH=arm "$VERIFIED/vmverify/tests/nopanic_check.sh" > "$LOGS/nopanic-arm.log" 2>&1; then
    cat "$LOGS/nopanic-arm.log"
    fail "device library links panic machinery on thumbv7m (nopanic_check.sh)"
  else
    grep -E '^no panic paths' "$LOGS/nopanic-arm.log"
  fi
}

sec_ec618_codegen() {
  section "EC618 (thumbv7m): code generation (thumb_codegen_check.sh)"
  if ! ec618_tools; then
    skip "no thumbv7m-none-eabi Rust target or no arm-none-eabi-gcc"
  elif ! "$VERIFIED/vmverify/tests/thumb_codegen_check.sh" > "$LOGS/thumb-codegen.log" 2>&1; then
    cat "$LOGS/thumb-codegen.log"
    fail "thumbv7m code generation (thumb_codegen_check.sh)"
  else
    grep -E '^thumb codegen ok' "$LOGS/thumb-codegen.log"
  fi
}

sec_sandbox_ctests() {
  section "Sandbox ctests"
  if [ -f "$BUILD_DIR/CTestTestfile.cmake" ] && [ -x "$BUILD_DIR/sdk/bin/toit" ]; then
    # tests/sandbox/CMakeLists.txt finds the tests with file(GLOB) at
    # configure time: a test file added since the last configuration would
    # silently not run. Reconfigure, then require one registered test per
    # tests/sandbox/*-test.toit (none of them is in TOIT_SKIP_TESTS).
    if ! (cd "$BUILD_DIR" && build_locked cmake . > "$LOGS/sandbox-cmake.log" 2>&1); then
      tail -20 "$LOGS/sandbox-cmake.log"
      fail "sandbox ctests: reconfiguring $BUILD_DIR"
    fi
    local on_disk registered
    on_disk=$(ls "$REPO"/tests/sandbox/*-test.toit | wc -l)
    registered=$(ctest --test-dir "$BUILD_DIR" -N -R '^tests/sandbox/[^ /]*-test\.toit$' \
      | sed -n 's/^Total Tests: //p')
    if [ "$on_disk" != "$registered" ]; then
      fail "sandbox ctests: $registered registered, $on_disk tests/sandbox/*-test.toit files"
    fi
    if ! ctest --test-dir "$BUILD_DIR" -R '^tests/sandbox/' -j "$(nproc)" --output-on-failure; then
      fail "sandbox ctests"
    fi
  else
    skip "no configured build with an SDK in $BUILD_DIR"
  fi
}

# A battery's log: a SKIP line in it (a battery that cannot run its line
# without a build) makes the section skipped, not passed.
battery_log_skips() {
  if grep -q '^SKIP' "$1"; then
    grep '^SKIP' "$1"
    SECTION_SKIPPED=1
  fi
}

# The red team's crafted heaps and assembled methods (round 3), on the
# normal build against each second build present: ASan/UBSan (build/asan)
# and Debug with assertions (build/dbg/host, `make BUILD=build/dbg
# BUILD_TYPE=Debug sdk`). Every case must be rejected or run safely, with
# the recorded verdict (review/red-team/round3/repro). Optional: skipped
# when there is no second build.
redteam3() {
  local battery="$1"
  section "Red-team battery $battery (review/red-team/round3/battery-$battery.sh)"
  local rt3="$REPO/review/red-team/round3" seconds=() b tag
  for b in "$REPO/build/asan/sdk/lib/toit/bin/toit.run" "$REPO/build/dbg/host/sdk/lib/toit/bin/toit.run"; do
    [ -x "$b" ] && seconds+=("$b")
  done
  if [ ! -x "$rt3/battery-$battery.sh" ] || [ ! -x "$BUILD_DIR/sdk/lib/toit/bin/toit.run" ]; then
    skip "no batteries or no toit.run in $BUILD_DIR"
  elif [ ${#seconds[@]} -eq 0 ]; then
    skip "no second build (build/asan or build/dbg/host)"
  else
    for b in "${seconds[@]}"; do
      case "$b" in */build/asan/*) tag=asan ;; *) tag=debug ;; esac
      if HOSTRUN="$BUILD_DIR/sdk/lib/toit/bin/toit.run" ASANRUN="$b" WORK="$LOGS/rt3-$tag-$battery" \
          "$rt3/battery-$battery.sh" > "$LOGS/battery-$battery-$tag.log" 2>&1; then
        echo "$tag: $(tail -1 "$LOGS/battery-$battery-$tag.log")"
      else
        tail -20 "$LOGS/battery-$battery-$tag.log"
        fail "red-team battery $battery ($tag)"
      fi
    done
  fi
}
sec_redteam3_heap() { redteam3 heap; }
sec_redteam3_asm() { redteam3 asm; }

# Red-team round 4 (review/red-team/round4): trusted/untrusted confusion (A),
# install lifecycle (B), 32/64 differential (C), crafted collections (D),
# service layer (E), free hunting (F). Each battery self-checks (named
# verifier rule, certificate rejection, loader bound, 64==32, or ASan clean)
# and exits non-zero on a finding. A needs build/asan; C needs build/host32;
# D, E and F are skipped without build/asan (E and F would otherwise run
# on the normal build only).
redteam4() {
  local battery="$1"
  section "Red-team round-4 battery $battery (review/red-team/round4/battery-$battery.sh)"
  local rt4="$REPO/review/red-team/round4"
  local normal="$BUILD_DIR/sdk/lib/toit/bin/toit.run"
  local asan="$REPO/build/asan/sdk/lib/toit/bin/toit.run"
  local h32="$REPO/build/host32/sdk/lib/toit/bin/toit.run"
  local log="$LOGS/battery-rt4-$battery.log"
  if [ ! -x "$rt4/battery-$battery.sh" ] || [ ! -x "$normal" ]; then
    skip "no round-4 batteries or no toit.run in $BUILD_DIR"
    return
  fi
  case "$battery" in
    C) [ -x "$h32" ] || { skip "line C: no 32-bit build at $h32 (make TARGET=host32 sdk)"; return; } ;;
    D|E|F) [ -x "$asan" ] || { skip "line $battery: no ASan build at $asan"; return; } ;;
  esac
  if HOSTRUN="$normal" ASANRUN="$asan" HOST32="$h32" WORK="$LOGS/rt4-$battery" \
      "$rt4/battery-$battery.sh" > "$log" 2>&1; then
    echo "round4-$battery: $(tail -1 "$log")"
    battery_log_skips "$log"
  else
    tail -20 "$log"
    fail "red-team round-4 battery $battery"
  fi
}
sec_redteam4_A() { redteam4 A; }
sec_redteam4_A_cert() { redteam4 A-cert; }
sec_redteam4_B() { redteam4 B; }
sec_redteam4_C() { redteam4 C; }
sec_redteam4_D() { redteam4 D; }
sec_redteam4_E() { redteam4 E; }
sec_redteam4_F() { redteam4 F; }

for s in "${SECTIONS[@]}"; do
  before=${#FAILURES[@]}
  SECTION_SKIPPED=0
  start=$(date +%s)
  "sec_${s//-/_}"
  secs=$(($(date +%s) - start))
  if [ ${#FAILURES[@]} -gt "$before" ]; then
    status=FAIL
  elif [ "$SECTION_SKIPPED" = 1 ]; then
    status=skipped
    SKIPPED+=("$s")
  else
    status=passed
  fi
  RESULTS+=("$(printf '%-22s %-8s %5d s' "$s" "$status" "$secs")")
done

section "Summary"
printf '  %s\n' "${RESULTS[@]}"
if [ ${#FAILURES[@]} -ne 0 ]; then
  echo "verified/check.sh FAILED:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
if [ ${#SKIPPED[@]} -ne 0 ]; then
  echo "skipped: ${SKIPPED[*]}"
  if [ -n "$ONLY" ]; then
    echo "verified/check.sh: no failures, but sections were skipped."
    exit 3
  fi
fi
echo "verified/check.sh passed."
