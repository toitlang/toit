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

# Checks the classic-ESP32 (Xtensa) build of the device library for the
# code patterns of the known wrong-code bugs of the esp-rs toolchain
# (verified/XTENSA-RUST-FIXES.md). The Toit toolchain fixes them
# (docs/xtensa-rust-toolchain.md); the check stays as a guard for other
# toolchains and for regressions. Builds the library as the firmware does
# (`cargo +toit-esp`, profile `device`, -Zbuild-std, -C save-temps) and
# fails if
#
#   llvm#140 / rust#284  a stack object is aligned above 16 bytes (IR), or
#                        any instruction but entry/movsp writes a1 (asm);
#   llvm#142 / rust#286  a function has a frame pointer or a variable-size
#                        alloca (IR), or SP moves at a call: any movsp (asm);
#   rust#278             a call across the language boundary passes more
#                        than six argument words with a sub-word integer or
#                        a byval object on the stack (IR signatures);
#   llvm#139 / rust#283  (with XTENSA_LLC_STOCK and XTENSA_LLC_FIXED, two
#                        llc builds of the fork's LLVM without and with the
#                        fix) the fixed llc compiles the library's bitcode
#                        differently from the stock one other than by
#                        commuting the operands of an add.
#
# Usage: xtensa_codegen_check.sh [OPT-LEVEL]   (default 3; s and z too)
# Needs the rustup toolchain XTENSA_RUST_TOOLCHAIN (default toit-esp) and
# ESP-IDF's xtensa-esp-elf GCC (objdump; on the PATH or in ~/.espressif).

set -euo pipefail
OPT="${1:-3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMVERIFY="$(cd "$HERE/.." && pwd)"
OUT="${OUT:-$VMVERIFY/target/xtensa-check-$OPT}"
TOOLCHAIN="${XTENSA_RUST_TOOLCHAIN:-toit-esp}"
if command -v xtensa-esp32-elf-objdump > /dev/null; then
  GCC_BIN="$(dirname "$(command -v xtensa-esp32-elf-objdump)")"
else
  GCC_BIN="$(ls -d "$HOME"/.espressif/tools/xtensa-esp-elf/*/xtensa-esp-elf/bin | sort -V | tail -n 1)"
fi
OBJDUMP="$GCC_BIN/xtensa-esp32-elf-objdump"
LLVM_DIS="${LLVM_DIS:-$(command -v llvm-dis || true)}"
mkdir -p "$OUT"
start=$(date +%s)
(cd "$VMVERIFY/staticlib" && PATH="$GCC_BIN:$PATH" CARGO_PROFILE_DEVICE_OPT_LEVEL="$OPT" RUSTFLAGS="-C save-temps" \
  cargo "+$TOOLCHAIN" build --quiet --profile device --no-default-features --features device-runtime \
    -Zbuild-std=core,alloc --target xtensa-esp32-none-elf --target-dir "$OUT/target")
LIB="$OUT/target/xtensa-esp32-none-elf/device/libtoit_rust.a"
rm -rf "$OUT/obj" "$OUT/bc"
mkdir -p "$OUT/obj" "$OUT/bc"
(cd "$OUT/obj" && "$GCC_BIN/xtensa-esp32-elf-ar" x "$LIB")
# The bitcode of exactly the objects in the library.
for o in "$OUT"/obj/*.o; do
  b="$(basename "$o" .o)"
  f="$(find "$OUT/target/xtensa-esp32-none-elf" -name "$b.bc" -newermt "@$((start - 1))" | head -1)"
  [ -n "$f" ] || f="$(find "$OUT/target/xtensa-esp32-none-elf" -name "$b.bc" | head -1)"
  [ -n "$f" ] && cp "$f" "$OUT/bc/"
done
status=0

# --- Assembly: SP writes and SP moves. --------------------------------------
for o in "$OUT"/obj/*.o; do "$OBJDUMP" -d --no-show-raw-insn "$o"; done > "$OUT/all.dis"
awk '
  /^Disassembly of section / { lit = ($4 ~ /^\.literal/); next }
  lit { next }
  /^[0-9a-f]+ <.*>:$/ { fn = $2; next }
  {
    line = $0; sub(/^ *[0-9a-f]+:\t/, "", line); split(line, p, "\t"); m = p[1]; ops = p[2]
    gsub(/ /, "", ops); n = split(ops, o, ",")
  }
  m == "movsp" { print "llvm#142: SP moved with movsp in " fn ": " line; bad++; next }
  n >= 1 && o[1] == "a1" && m !~ /^(entry|retw|retw\.n|s32i|s32i\.n|s16i|s8i|s32e|ssi|ssip|beqz|bnez|beqz\.n|bnez\.n|bltz|bgez|beq|bne|blt|bge|bltu|bgeu|bany|bnone|ball|bnall|bbc|bbs|bbci|bbsi|beqi|bnei|blti|bgei|bltui|bgeui|wsr.*|wur.*|wfr|s32c1i)$/ {
    print "llvm#140: a1 written in " fn ": " line; bad++
  }
  END { exit (bad > 0) }
' "$OUT/all.dis" || status=1

# --- IR: alignment, frame pointers, dynamic allocas, FFI signatures. --------
if [ -z "$LLVM_DIS" ]; then
  echo "llvm-dis not found (set LLVM_DIS): IR checks skipped" >&2
  status=1
else
  for f in "$OUT"/bc/*.bc; do "$LLVM_DIS" "$f" -o -; done > "$OUT/all.ll"
  if grep -n -E 'alloca [^,]+, align (32|64|128|256|512|[0-9]{4,})' "$OUT/all.ll"; then
    echo "llvm#140: stack object aligned above 16 bytes"; status=1
  fi
  if grep -n -E '= alloca [^,]+, i(32|64) %' "$OUT/all.ll"; then
    echo "llvm#142: variable-size alloca"; status=1
  fi
  if grep -n -E '"frame-pointer"="(all|non-leaf)"' "$OUT/all.ll" | head -3 | grep -q .; then
    echo "llvm#142: frame pointers enabled"; status=1
  fi
  # Language-boundary functions: declarations, and definitions that are
  # neither internal nor Rust-mangled.
  grep -E '^(declare|define) ' "$OUT/all.ll" | grep -v -E '@llvm\.' \
    | grep -v -E '^define (internal|private|hidden internal|linkonce|weak)' \
    | awk '
      {
        name = $0; sub(/^[^@]*@/, "", name); sub(/\(.*/, "", name)
        if (name ~ /^_R/ || name ~ /^_ZN/) next
        args = $0; sub(/^[^(]*\(/, "", args); sub(/\)[^)]*$/, "", args)
        depth = 0; cur = ""; n = 0; delete a
        for (i = 1; i <= length(args); i++) {
          c = substr(args, i, 1)
          if (c ~ /[({[<]/) depth++
          if (c ~ /[)}\]>]/) depth--
          if (c == "," && depth == 0) { a[++n] = cur; cur = ""; continue }
          cur = cur c
        }
        if (cur != "") a[++n] = cur
        w = 0
        for (j = 1; j <= n; j++) {
          t = a[j]; sub(/^ +/, "", t)
          if (t == "...") continue
          ww = (t ~ /^(i64|double)/) ? 2 : ((t ~ /^i128/) ? 4 : 1)
          if (ww == 2 && w % 2 == 1) w++
          if (w + ww > 6 && (t ~ /^i(8|16)( |$)/ || t ~ /byval/)) { print "rust#278: stack argument " j " of " name ": " t; bad++ }
          w += ww
        }
      }
      END { exit (bad > 0) }' || status=1
fi

# --- Differential compile for llvm#139 (optional). --------------------------
if [ -n "${XTENSA_LLC_STOCK:-}" ] && [ -n "${XTENSA_LLC_FIXED:-}" ]; then
  case "$OPT" in 3) OL=-O3 ;; *) OL=-O2 ;; esac
  for f in "$OUT"/bc/*.bc; do
    b="$(basename "$f" .bc)"
    ol=$OL; case "$b" in toit_spec-*) ol=-O2 ;; esac
    for v in STOCK FIXED; do
      llc="XTENSA_LLC_$v"
      "${!llc}" "$ol" -mcpu=esp32 -relocation-model=static -function-sections -data-sections \
        -filetype=obj "$f" -o "$OUT/$b.$v.o"
      "$OBJDUMP" -d --no-show-raw-insn "$OUT/$b.$v.o" | tail -n +4 > "$OUT/$b.$v.dis"
    done
    # A difference other than the commuted operands of an add (the fix
    # also changes how an aggregate constant's address is formed). Counted,
    # not grepped: `grep -q` would end the pipeline early (pipefail).
    n="$(diff "$OUT/$b.STOCK.dis" "$OUT/$b.FIXED.dis" | grep '^[<>]' \
        | sed -E 's/add(\.n)?\t(a[0-9]+), (a[0-9]+), (a[0-9]+)/add \2 {\3 \4}/' \
        | awk '/^[<>].*add a[0-9]+ \{/ { split($0, x, /[{}]/); split(x[2], r, " "); k = (r[1] < r[2]) ? r[1] " " r[2] : r[2] " " r[1]; sub(/\{.*\}/, "{" k "}"); } { print substr($0, 3) }' \
        | sort | uniq -u | wc -l)" || true
    if [ "$n" -gt 0 ]; then
      echo "llvm#139: the fixed llc compiles $b differently"; status=1
    fi
  done
fi

if [ $status -eq 0 ]; then echo "xtensa_codegen_check: opt $OPT: none of the known wrong-code patterns"; fi
exit $status
