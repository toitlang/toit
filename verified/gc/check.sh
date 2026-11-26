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

# Checks the proved collector (verified/gc, README.md):
#   verus    Verus with 64-bit words, the bridge included (the spec and
#            core crates imported from their exported metadata; they are
#            verified by verified/check.sh, here only exported).
#   verus32  The same with 32-bit words (i686, verified/tools/verus_target.sh).
#   audit    The escape hatches of src/ against TRUSTED.toml (counts per file
#            and kind; unlisted or changed counts fail), cross-checked with
#            `verus --no-cheating`: every location it rejects must be listed.
#   test     cargo test, 64-bit and i686.
#   nopanic  The collector behind a C entry (nopanic/) linked for riscv32imac
#            and thumbv7m with --gc-sections: no panic or formatting
#            machinery may survive; prints the code size.
#
# Usage: verified/gc/check.sh [--only NAME[,NAME...]]
# Exit code non-zero on any failure.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIED="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$VERIFIED/.." && pwd)"
BUILD="$REPO/build/gc-check"
mkdir -p "$BUILD"
export TMPDIR="${TMPDIR:-$REPO/build/tmp}"
mkdir -p "$TMPDIR"
JOBS="${JOBS:-6}"

ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) shift; ONLY="$1" ;;
    -h|--help) sed -n '/^# Checks/,/^# Exit/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
want() { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }

FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }
section() { echo; echo "== $*"; }

W32_TARGET=i686-unknown-linux-gnu
CORE_CFGS=(--cfg toit_vcore_hosted --cfg 'feature="checked-loop"' --cfg 'feature="layout-tables"' --cfg 'feature="preempt-a-lot"')

# The spec's and the core's metadata for the import, per word width, cached
# by the hash of their sources.
deps_hash() {
  (cd "$VERIFIED" && find spec/src core/src spec/Cargo.toml core/Cargo.toml -type f -print0 | sort -z \
     | xargs -0 sha256sum | sha256sum | cut -c1-16)
}
export_deps() {  # VERUS OUTDIR [TARGET-ARGS...]
  local verus="$1" out="$2"; shift 2
  if [ -f "$out/done" ]; then return 0; fi
  mkdir -p "$out"
  (cd "$VERIFIED/spec" && "$verus" --crate-type=lib "$@" --crate-name toit_spec src/lib.rs --no-verify \
      --export "$out/toit_spec.vir" --compile -o "$out/libtoit_spec.rlib") > "$out/spec.log" 2>&1 || return 1
  (cd "$VERIFIED/core" && "$verus" --crate-type=lib "$@" --crate-name toit_verified_core "${CORE_CFGS[@]}" \
      --extern "toit_spec=$out/libtoit_spec.rlib" --import "toit_spec=$out/toit_spec.vir" src/lib.rs --no-verify \
      --export "$out/toit_verified_core.vir" --compile -o "$out/libtoit_verified_core.rlib") > "$out/core.log" 2>&1 || return 1
  touch "$out/done"
}
bridge_args() {  # OUTDIR
  echo "--cfg toit_gc_bridge --extern toit_spec=$1/libtoit_spec.rlib --import toit_spec=$1/toit_spec.vir" \
       "--extern toit_verified_core=$1/libtoit_verified_core.rlib --import toit_verified_core=$1/toit_verified_core.vir"
}
run_verus() {  # NAME VERUS LOG [ARGS...]
  local name="$1" verus="$2" log="$3"; shift 3
  local start end rc result
  start=$(date +%s.%N)
  (cd "$HERE" && "$verus" --crate-type=lib "$@" src/lib.rs --time) > "$log" 2>&1
  rc=$?
  end=$(date +%s.%N)
  result=$(grep -E '^verification results:: ' "$log" | tail -1)
  printf '%-8s %s; total %s ms (SMT %s ms), wall %s s\n' "$name" "${result#verification results:: }" \
    "$(grep -E '^total-time:' "$log" | tail -1 | awk '{print $2}')" \
    "$(grep -E 'total smt-time:' "$log" | tail -1 | awk '{print $3}')" \
    "$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", e - s }')"
  if [ "$rc" -ne 0 ] || [[ "$result" != *" 0 errors"* ]]; then
    grep -E '^error|^ *--> ' "$log" | head -40
    fail "$name: Verus did not report 0 errors (log: $log)"
  fi
}

HASH="$(deps_hash)"

if want verus; then
  section "Verus, 64-bit words ($(verus --version 2>/dev/null | sed -n 's/^ *Version: //p'))"
  D64="$REPO/build/gcdeps/$HASH/w64"
  if export_deps verus "$D64"; then
    # shellcheck disable=SC2046
    run_verus gc verus "$BUILD/verus64.log" $(bridge_args "$D64")
  else
    fail "cannot export the spec and core crates (logs in $D64)"
  fi
fi

if want verus32; then
  section "Verus, 32-bit words ($W32_TARGET)"
  if VERUS32="$(flock "$REPO/build/.verus-target.lock" "$VERIFIED/tools/verus_target.sh" "$W32_TARGET" "$REPO/build/verus-$W32_TARGET")"; then
    D32="$REPO/build/gcdeps/$HASH/w32"
    if export_deps "$VERUS32" "$D32" --target "$W32_TARGET"; then
      # shellcheck disable=SC2046
      run_verus gc32 "$VERUS32" "$BUILD/verus32.log" --target "$W32_TARGET" $(bridge_args "$D32")
    else
      fail "cannot export the spec and core crates for $W32_TARGET (logs in $D32)"
    fi
  else
    fail "cannot set up Verus for $W32_TARGET"
  fi
fi

if want audit; then
  section "Escape hatches (TRUSTED.toml)"
  # Occurrences per file and kind, in code (comments stripped).
  found="$BUILD/hatches.txt"
  : > "$found"
  for f in "$HERE"/src/*.rs; do
    rel="src/$(basename "$f")"
    code="$(sed -e 's://.*$::' "$f")"
    for pat in 'external_body:external_body' 'external_fn_specification:external_fn_specification' \
               'assume_specification:assume_specification' 'verifier::external\b:external' \
               '\bassume\(:assume' '\badmit\(:admit' 'assume_new:assume_new' '\bunsafe\b:unsafe' \
               'global size_of:global_layout' 'verifier::truncate:truncate' 'inline_air:inline_air' \
               'assume_termination:assume_termination' 'exec_allows_no_decreases_clause:no_decreases'; do
      re="${pat%%:*}"; kind="${pat##*:}"
      n=$(grep -cE "$re" <<< "$code" || true)
      if [ "$n" -gt 0 ]; then echo "$rel $kind $n" >> "$found"; fi
    done
  done
  listed="$BUILD/listed.txt"
  awk -F' = ' '/^file/ {gsub(/"/, "", $2); f=$2} /^kind/ {gsub(/"/, "", $2); k=$2} /^count/ {print f, k, $2}' \
    "$HERE/TRUSTED.toml" > "$listed"
  if diff <(sort "$found") <(sort "$listed") > "$BUILD/hatches.diff"; then
    echo "escape hatches match TRUSTED.toml ($(wc -l < "$found") entries)"
  else
    cat "$BUILD/hatches.diff"
    fail "escape hatches differ from TRUSTED.toml (< found, > listed)"
  fi
  # Verus' own detector: each rejected location must be a listed file.
  D64="$REPO/build/gcdeps/$HASH/w64"
  if export_deps verus "$D64"; then
    # shellcheck disable=SC2046
    (cd "$HERE" && verus --crate-type=lib $(bridge_args "$D64") src/lib.rs --no-cheating --no-verify) > "$BUILD/nocheat.log" 2>&1
    bad=0
    while read -r loc; do
      file="${loc%%:*}"
      if ! awk '{print $1}' "$listed" | grep -qx "$file"; then echo "unlisted: $loc"; bad=1; fi
    done < <(grep -A1 -E 'not allowed with `--no-cheating`' "$BUILD/nocheat.log" | sed -n 's/^ *--> \(src\/[^ ]*\)$/\1/p')
    if [ "$bad" -ne 0 ]; then fail "verus --no-cheating rejects unlisted locations"; else
      echo "verus --no-cheating: $(grep -c 'not allowed with `--no-cheating`' "$BUILD/nocheat.log") rejected locations, all listed"
    fi
  fi
fi

if want test; then
  section "Tests (cargo test, 64-bit and $W32_TARGET)"
  for target in "" "$W32_TARGET"; do
    targs=()
    [ -n "$target" ] && targs=(--target "$target")
    if (cd "$HERE" && CARGO_TARGET_DIR="$REPO/build/gc-target" cargo test -q -j"$JOBS" --release "${targs[@]}") \
        > "$BUILD/test${target:+-$target}.log" 2>&1; then
      echo "${target:-host}: $(grep -E '^test result' "$BUILD/test${target:+-$target}.log" | awk '{s += $4} END {print s}') tests passed"
    else
      tail -30 "$BUILD/test${target:+-$target}.log"
      fail "cargo test ${target:-host}"
    fi
  done
fi

if want nopanic; then
  section "No panic paths (riscv32imac, thumbv7m; opt-level s)"
  FORBIDDEN='core::panicking|core::fmt|rust_begin_unwind|toit_gc_panic|panic_bounds_check|slice_index|slice_start_index|slice_end_index|unwrap_failed|expect_failed|handle_alloc_error|capacity_overflow'
  RVGCC="$(command -v riscv32-esp-elf-gcc || ls -d "$HOME"/.espressif/tools/riscv32-esp-elf/esp-1[0-9]*/riscv32-esp-elf/bin/riscv32-esp-elf-gcc 2>/dev/null | sort -V | tail -1)"
  for spec in "riscv32imac-unknown-none-elf:$RVGCC:-march=rv32imac_zicsr_zifencei -mabi=ilp32" \
              "thumbv7m-none-eabi:$(command -v arm-none-eabi-gcc):-mcpu=cortex-m3 -mthumb"; do
    target="${spec%%:*}"; rest="${spec#*:}"; gcc="${rest%%:*}"; flags="${rest#*:}"
    if [ -z "$gcc" ] || [ ! -x "$gcc" ]; then fail "$target: no C toolchain"; continue; fi
    prefix="$(basename "$gcc" | sed 's/-gcc$//')"
    nm="$(dirname "$gcc")/$prefix-nm"; size="$(dirname "$gcc")/$prefix-size"
    tdir="$REPO/build/gc-nopanic"
    if ! (cd "$HERE/nopanic" && CARGO_TARGET_DIR="$tdir" cargo build -q -j"$JOBS" --release --target "$target") > "$BUILD/nopanic-$target.log" 2>&1; then
      tail -20 "$BUILD/nopanic-$target.log"; fail "$target: build"; continue
    fi
    elf="$BUILD/nopanic-$target.elf"
    # shellcheck disable=SC2086
    if ! "$gcc" $flags -nostdlib -Os -ffunction-sections -Wl,--gc-sections -Wl,-e,toit_gc_collect -Wl,-u,toit_gc_collect \
        -o "$elf" "$HERE/nopanic/stubs.c" "$tdir/$target/release/libtoit_gc_nopanic.a" >> "$BUILD/nopanic-$target.log" 2>&1; then
      tail -20 "$BUILD/nopanic-$target.log"; fail "$target: link"; continue
    fi
    if "$nm" -C "$elf" | grep -E "$FORBIDDEN"; then
      fail "$target: panic machinery linked"
    else
      stubs=$("$nm" -S --defined-only "$elf" | awk '/ toit_gc_page_| toit_gc_panic/ {s += strtonum("0x" $2)} END {print s + 0}')
      text=$("$size" -A "$elf" | awk '$1 == ".text" {print $2}')
      echo "$target: no panic paths; collector .text $((text - stubs)) bytes"
    fi
  done
fi

echo
if [ "$FAILED" -ne 0 ]; then echo "verified/gc/check.sh: FAILED"; exit 1; fi
echo "verified/gc/check.sh: all checks passed"
