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
#      64-bit words (the host) and for 32-bit words (i686 target).
#   2. Escape-hatch audit against verified/TRUSTED.toml (and a cross-check
#      with `verus --no-cheating`); writes verified/THEOREMS.txt. The leaf
#      contracts of verified/CONTRACTS.toml against both of their sides.
#   3. With --tests: the audit's regression test, layout check, the
#      VeriFast proofs of the residual C++ (verified/cxx/annotated), spec
#      differential tests, the device library's no-panic check, sandbox
#      ctests, and (optional, when a second build exists) the red-team
#      batteries. The residual C++ matrix runs its fast tier.
#   4. With --slow (implies --tests): also the slow tier of the residual
#      C++ matrix (verified/cxx/annotated/run.sh --slow: the long
#      model-checker jobs; hours, memory-capped).
#
# Usage: verified/check.sh [--tests] [--slow] [--update-allowlist] [--build DIR]
# Exit code is non-zero on any failure.

set -u -o pipefail

VERIFIED="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$VERIFIED/.." && pwd)"
BUILD_DIR="$REPO/build/host"
RUN_TESTS=0
RUN_SLOW=0
AUDIT_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --tests) RUN_TESTS=1 ;;
    --slow) RUN_TESTS=1; RUN_SLOW=1 ;;
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
# verified/tools/trust_audit.toit. Commands from verified/core/NOTES.md and
# verified/spec/DESIGN.md. The spec crate is verified first and exports its
# Verus metadata and an rlib; the core imports both (it is proven against
# the spec's definitions, verified/core/DESIGN.md section 9).
# The core is verified with its `checked-loop` and `layout-tables` features
# (the defaults; devices build without them, which only leaves code out:
# verified/core/Cargo.toml) and `preempt-a-lot` (debug VM builds only).
CRATES=(spec core)
crate_args() {
  case "$1" in
    core) echo "--crate-name toit_verified_core --cfg toit_vcore_hosted --cfg feature=\"checked-loop\" --cfg feature=\"layout-tables\" --cfg feature=\"preempt-a-lot\" --extern toit_spec=$LOGS/libtoit_spec.rlib --import toit_spec=$LOGS/toit_spec.vir" ;;
    spec) echo "--crate-name toit_spec" ;;
  esac
}
# Arguments of the verifying run only (not of the --no-cheating cross-check).
crate_verify_args() {
  case "$1" in
    core) echo "" ;;
    spec) echo "--export $LOGS/toit_spec.vir --compile -o $LOGS/libtoit_spec.rlib" ;;
  esac
}

# Runs Verus on one crate. Direct `verus` is preferred (the crates' documented
# command); `cargo verus verify` is the fallback when only cargo-verus exists.
verify_crate() {
  local name="$1"
  local dir="$VERIFIED/$name"
  local log="$LOGS/$name.log"
  local args vargs
  read -r -a args <<< "$(crate_args "$name")"
  read -r -a vargs <<< "$(crate_verify_args "$name")"
  local start end rc
  start=$(date +%s.%N)
  if command -v verus > /dev/null; then
    (cd "$dir" && verus --crate-type=lib "${args[@]}" "${vargs[@]}" src/lib.rs --time) > "$log" 2>&1
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
    AUDIT_ARGS+=(--verus-no-cheating-log "$name=$LOGS/$name.nocheat.log")
  fi
}

section "Verus ($(verus --version 2>/dev/null | sed -n 's/^ *Version: //p'))"
for c in "${CRATES[@]}"; do
  verify_crate "$c"
done

# The same crates for 32-bit words: Verus with `--target
# i686-unknown-linux-gnu` and its support libraries built for that target
# (verified/tools/verus_target.sh), so that `usize` is 32 bits wide in every
# proof (the core's `global size_of usize` is per target_pointer_width; the
# crates' code is the same except for the cfg'd constants of layout.rs).
# This is the proof for the 32-bit host and the riscv32 devices.
verify_crate_word32() {
  local name="$1"
  local dir="$VERIFIED/$name"
  local log="$LOGS/$name.word32.log"
  local args=()
  case "$name" in
    spec) args=(--crate-name toit_spec --export "$LOGS/w32/toit_spec.vir" --compile -o "$LOGS/w32/libtoit_spec.rlib") ;;
    core) args=(--crate-name toit_verified_core --cfg toit_vcore_hosted --cfg 'feature="checked-loop"' --cfg 'feature="layout-tables"' --cfg 'feature="preempt-a-lot"'
                --extern "toit_spec=$LOGS/w32/libtoit_spec.rlib" --import "toit_spec=$LOGS/w32/toit_spec.vir") ;;
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
section "Verus, 32-bit words ($WORD32_TARGET)"
mkdir -p "$LOGS/w32"
if VERUS32="$("$VERIFIED/tools/verus_target.sh" "$WORD32_TARGET" "$REPO/build/verus-$WORD32_TARGET")"; then
  for c in "${CRATES[@]}"; do
    verify_crate_word32 "$c"
  done
else
  fail "32-bit words: cannot set up Verus for $WORD32_TARGET (verified/tools/verus_target.sh; rustup target add $WORD32_TARGET)"
fi

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
  if [ ! -f "$VERIFIED/tools/.packages/contents.json" ] \
      || [ "$VERIFIED/tools/package.lock" -nt "$VERIFIED/tools/.packages/contents.json" ]; then
    "$TOIT_BIN" pkg install --project-root "$VERIFIED/tools" || return 1
  fi
}

section "Escape-hatch audit"
if ! tools_ready; then
  fail "escape-hatch audit: cannot run verified/tools/trust_audit.toit"
elif ! "$TOIT_BIN" run "$VERIFIED/tools/trust_audit.toit" -- --root "$VERIFIED" "${AUDIT_ARGS[@]}"; then
  fail "escape-hatch audit (see above)"
fi

section "Leaf contracts, Verus and VeriFast (verified/CONTRACTS.toml)"
if ! tools_ready; then
  fail "contract table: cannot run verified/tools/contract_check.toit"
elif ! "$TOIT_BIN" run "$VERIFIED/tools/contract_check.toit" -- --root "$VERIFIED"; then
  fail "contract table: a Verus or VeriFast contract differs from verified/CONTRACTS.toml (see above)"
fi

section "Layout facts, Verus and VeriFast (verified/LAYOUT.toml)"
# Against layout.rs here; against the C++ and the VeriFast model by the
# generated static assertions, compiled in the VeriFast section.
if ! tools_ready; then
  fail "layout table: cannot run verified/tools/layout_table.toit"
elif ! "$TOIT_BIN" run "$VERIFIED/tools/layout_table.toit" -- --check --root "$VERIFIED"; then
  fail "layout table: verified/LAYOUT.toml differs from layout.rs or its generated checks (see above)"
fi

if [ "$RUN_TESTS" = 1 ]; then
  section "IEEE binary64 specification checks"
  z3_bin="${VERUS_Z3_PATH:-$(command -v z3)}"
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

  section "Escape-hatch audit regression test (verified/tools/tests/trust_audit_test.sh)"
  if ! tools_ready || ! TOIT="$TOIT_BIN" "$VERIFIED/tools/tests/trust_audit_test.sh"; then
    fail "escape-hatch audit regression test"
  fi

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

  section "VeriFast proofs of the residual C++ (verified/cxx/annotated/run.sh)"
  # The renderings must match the sources (drift fails), the constants the
  # headers, and every proof and reverted-bug self-test its verdict. Skipped
  # (exit status 3) when VeriFast is not installed.
  if ! tools_ready; then
    fail "VeriFast proofs: cannot run verified/tools/cxx_render.toit"
  else
    TOIT="$TOIT_BIN" "$VERIFIED/cxx/annotated/run.sh" > "$LOGS/verifast.log" 2>&1
    vf_status=$?
    if [ $vf_status -eq 3 ]; then
      grep '^SKIP' "$LOGS/verifast.log"
    elif [ $vf_status -eq 4 ]; then
      grep '^NOVERDICT' "$LOGS/verifast.log" | head -40
      fail "VeriFast matrix of the residual C++: a model-checker job gave no verdict (out of time or memory)"
    elif [ $vf_status -ne 0 ]; then
      grep -v '^ok' "$LOGS/verifast.log" | head -40
      fail "VeriFast proofs of the residual C++ (a proof failed or a rendering drifted)"
    else
      echo "$(grep -c '^ok' "$LOGS/verifast.log") checks passed ($(tail -1 "$LOGS/verifast.log"))"
    fi
    if [ "$RUN_SLOW" = 1 ]; then
      section "The slow tier of the residual C++'s model-checker jobs (run.sh --slow)"
      # Hours; memory-capped jobs, see the README's slow-tier table.
      TOIT="$TOIT_BIN" "$VERIFIED/cxx/annotated/run.sh" --slow > "$LOGS/slow.log" 2>&1
      slow_status=$?
      grep -v '^ok' "$LOGS/slow.log" | head -60
      if [ $slow_status -eq 4 ]; then
        fail "slow tier: no verdict for some jobs (out of time or memory; nothing refuted)"
      elif [ $slow_status -ne 0 ]; then
        fail "slow tier: a model-checker job failed"
      else
        echo "$(grep -c '^ok' "$LOGS/slow.log") slow-tier jobs passed"
      fi
    fi
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
    echo "SKIP: $BUILD_DIR/sdk/bin/toit missing (make sdk)"
  fi

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
    echo "SKIP: no riscv32-esp-elf-gcc (ESP-IDF toolchain)"
  fi

  section "EC618 (thumbv7m): no panic paths, code generation (nopanic_check.sh, thumb_codegen_check.sh)"
  if rustup target list --installed 2> /dev/null | grep -q '^thumbv7m-none-eabi$' \
      && { [ -x "${EC618_GCC_PATH:-/nonexistent}/bin/arm-none-eabi-gcc" ] \
           || ls "$HOME"/.xmake/packages/g/gnu_rm/*/*/bin/arm-none-eabi-gcc > /dev/null 2>&1 \
           || command -v arm-none-eabi-gcc > /dev/null; }; then
    if ! NOPANIC_ARCH=arm "$VERIFIED/vmverify/tests/nopanic_check.sh" > "$LOGS/nopanic-arm.log" 2>&1; then
      cat "$LOGS/nopanic-arm.log"
      fail "device library links panic machinery on thumbv7m (nopanic_check.sh)"
    else
      grep -E '^no panic paths' "$LOGS/nopanic-arm.log"
    fi
    if ! "$VERIFIED/vmverify/tests/thumb_codegen_check.sh" > "$LOGS/thumb-codegen.log" 2>&1; then
      cat "$LOGS/thumb-codegen.log"
      fail "thumbv7m code generation (thumb_codegen_check.sh)"
    else
      grep -E '^thumb codegen ok' "$LOGS/thumb-codegen.log"
    fi
  else
    echo "SKIP: no thumbv7m-none-eabi Rust target or no arm-none-eabi-gcc"
  fi

  section "Sandbox ctests"
  if [ -f "$BUILD_DIR/CTestTestfile.cmake" ] && [ -x "$BUILD_DIR/sdk/bin/toit" ]; then
    # tests/sandbox/CMakeLists.txt finds the tests with file(GLOB) at
    # configure time: a test file added since the last configuration would
    # silently not run. Reconfigure, then require one registered test per
    # tests/sandbox/*-test.toit (none of them is in TOIT_SKIP_TESTS).
    if ! (cd "$BUILD_DIR" && cmake . > "$LOGS/sandbox-cmake.log" 2>&1); then
      tail -20 "$LOGS/sandbox-cmake.log"
      fail "sandbox ctests: reconfiguring $BUILD_DIR"
    fi
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
    echo "SKIP: no configured build with an SDK in $BUILD_DIR"
  fi

  # Optional: the red team's crafted heaps and assembled methods (round 3),
  # on the normal build against each second build present: ASan/UBSan
  # (build/asan) and Debug with assertions (build/dbg/host, `make
  # BUILD=build/dbg BUILD_TYPE=Debug sdk`). Every case must be rejected or
  # run safely, with the recorded verdict (review/red-team/round3/repro).
  section "Red-team batteries (review/red-team/round3/battery-{heap,asm}.sh)"
  RT3="$REPO/review/red-team/round3"
  SECONDS_BUILDS=()
  for b in "$REPO/build/asan/sdk/lib/toit/bin/toit.run" "$REPO/build/dbg/host/sdk/lib/toit/bin/toit.run"; do
    [ -x "$b" ] && SECONDS_BUILDS+=("$b")
  done
  if [ ! -x "$RT3/battery-heap.sh" ] || [ ! -x "$BUILD_DIR/sdk/lib/toit/bin/toit.run" ]; then
    echo "SKIP: no batteries or no toit.run in $BUILD_DIR"
  elif [ ${#SECONDS_BUILDS[@]} -eq 0 ]; then
    echo "SKIP: no second build (build/asan or build/dbg/host)"
  else
    for b in "${SECONDS_BUILDS[@]}"; do
      case "$b" in */build/asan/*) tag=asan ;; *) tag=debug ;; esac
      for battery in heap asm; do
        if HOSTRUN="$BUILD_DIR/sdk/lib/toit/bin/toit.run" ASANRUN="$b" WORK="$LOGS/rt3-$tag" \
            "$RT3/battery-$battery.sh" > "$LOGS/battery-$battery-$tag.log" 2>&1; then
          echo "$tag: $(tail -1 "$LOGS/battery-$battery-$tag.log")"
        else
          tail -20 "$LOGS/battery-$battery-$tag.log"
          fail "red-team battery $battery ($tag)"
        fi
      done
    done
  fi

  # Red-team round 4 (review/red-team/round4): trusted/untrusted confusion (A),
  # install lifecycle (B), 32/64 differential (C), crafted collections (D),
  # service layer (E), free hunting (F). Each battery self-checks (named
  # verifier rule, certificate rejection, loader bound, 64==32, or ASan clean)
  # and exits non-zero on a finding. A needs build/asan; C needs build/host32.
  section "Red-team round-4 batteries (review/red-team/round4/battery-{A,A-cert,B,C,D,E,F}.sh)"
  RT4="$REPO/review/red-team/round4"
  RT4_NORMAL="$BUILD_DIR/sdk/lib/toit/bin/toit.run"
  RT4_ASAN="$REPO/build/asan/sdk/lib/toit/bin/toit.run"
  RT4_H32="$REPO/build/host32/sdk/lib/toit/bin/toit.run"
  if [ ! -x "$RT4/battery-A.sh" ] || [ ! -x "$RT4_NORMAL" ]; then
    echo "SKIP: no round-4 batteries or no toit.run in $BUILD_DIR"
  else
    for battery in A A-cert B C D E F; do
      if HOSTRUN="$RT4_NORMAL" ASANRUN="$RT4_ASAN" HOST32="$RT4_H32" WORK="$LOGS/rt4" \
          "$RT4/battery-$battery.sh" > "$LOGS/battery-rt4-$battery.log" 2>&1; then
        echo "round4-$battery: $(tail -1 "$LOGS/battery-rt4-$battery.log")"
      else
        tail -20 "$LOGS/battery-rt4-$battery.log"
        fail "red-team round-4 battery $battery"
      fi
    done
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
