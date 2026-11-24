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

# Code-generation check of the EC618 (Cortex-M3, thumbv7m-none-eabi) build
# of the device library. thumbv7m-none-eabi is an upstream tier-2 target
# with stock LLVM (no fork, no known wrong-code bugs as on Xtensa), so this
# checks what the EC618 firmware assumes rather than compiler bugs. Builds
# the library as the firmware does (profile `device`, ../.cargo/config.toml),
# links it into the minimal executable of device_size.sh with --emit-relocs
# and fails if
#
#   abi       the core's object is not v7-M Thumb-2 without ARM code and
#             without floating-point hardware, or its wchar_t and stack
#             alignment differ from the GCC objects of the VM (the FFI
#             structs follow the C ABI on both sides; they hold no enums,
#             whose size GCC's arm-none-eabi makes small);
#   movw      a linked instruction is relocated as a movw/movt pair: the
#             slot relocator (tools/ec618/gen-slot-reloc.toit) moves only
#             32-bit words and branches, so an address of slot code or
#             data must come from a literal pool (target-feature=+no-movt
#             in ../.cargo/config.toml);
#   fpu       a linked instruction is a VFP/NEON instruction;
#   atomics   the link needs __atomic_* or __sync_* helpers (v7-M has
#             LDREX/STREX: Rust's 8/16/32-bit atomics are native; the core
#             uses no 64-bit atomics).
#
# It also prints the largest stack frames of the linked Rust functions (the
# scheduler threads that run the core have 8 KB stacks, scheduler.cc).
#
# Usage: thumb_codegen_check.sh [OPT-LEVEL...]   (default: 3)
# Needs the thumbv7m-none-eabi Rust target and the EC618 SDK's GNU Arm
# toolchain (EC618_GCC_PATH or xmake's gnu_rm package, else
# arm-none-eabi-gcc on the PATH).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIED="$(cd "$HERE/../.." && pwd)"
WORK="$VERIFIED/../build/vmverify-thumb-check"
TARGET=thumbv7m-none-eabi
LEVELS=("$@")
if [ ${#LEVELS[@]} -eq 0 ]; then LEVELS=(3); fi

GCC="$(ls -d "${EC618_GCC_PATH:-/nonexistent}/bin/arm-none-eabi-gcc" \
    "$HOME"/.xmake/packages/g/gnu_rm/*/*/bin/arm-none-eabi-gcc 2>/dev/null | head -1 || true)"
[ -n "$GCC" ] || GCC="$(command -v arm-none-eabi-gcc || true)"
[ -x "$GCC" ] || { echo "arm-none-eabi-gcc not found" >&2; exit 1; }
BIN="$(dirname "$GCC")"
CFLAGS=(-mcpu=cortex-m3 -mthumb)

failed=0
fail() { echo "FAIL ($1): $2"; failed=1; }

# Both configurations of the run loop: split (the EC618's default,
# Makefile EC618_SPLIT_LOOP) and whole.
for loop in split whole; do
features=device-runtime
[ "$loop" = split ] && features=device-runtime,split-loop
for opt in "${LEVELS[@]}"; do
  out="$WORK/opt$opt-$loop"
  rm -rf "$out/obj"
  mkdir -p "$out/obj"
  echo "== device library, opt-level $opt, $loop loop ($TARGET)"
  (cd "$VERIFIED/vmverify/staticlib" && CARGO_PROFILE_DEVICE_OPT_LEVEL="$opt" cargo build --quiet --profile device --lib \
      --no-default-features --features "$features" --target "$TARGET" --target-dir "$out/target") 2>&1 \
      | grep -v -E "no-movt|unknown and unstable feature|still passed through|consider filing|^ *\|$|^ *= " || true
  lib="$out/target/$TARGET/device/libtoit_rust.a"
  (cd "$out/obj" && "$BIN/arm-none-eabi-ar" x "$lib")
  core_obj="$(ls "$out"/obj/toit_rust-*.o | head -1)"

  # --- ABI attributes against a GCC object of the VM's flags. -------------
  echo 'int f(void) { return 0; }' > "$out/ref.c"
  "$GCC" "${CFLAGS[@]}" -Os -specs=nano.specs -c "$out/ref.c" -o "$out/ref.o"
  "$BIN/arm-none-eabi-readelf" -A "$core_obj" > "$out/core.attr"
  "$BIN/arm-none-eabi-readelf" -A "$out/ref.o" > "$out/gcc.attr"
  for tag in "Tag_CPU_arch: v7" "Tag_CPU_arch_profile: Microcontroller" "Tag_ARM_ISA_use: No" "Tag_THUMB_ISA_use: Thumb-2"; do
    grep -q "$tag\$" "$out/core.attr" || fail abi "core object lacks '$tag'"
  done
  if grep -E "Tag_FP_arch|Tag_Advanced_SIMD_arch|Tag_ABI_VFP_args" "$out/core.attr"; then
    fail abi "core object uses floating-point hardware or its calling convention"
  fi
  for tag in Tag_ABI_PCS_wchar_t Tag_ABI_align_needed Tag_ABI_align_preserved; do
    a="$(grep "$tag:" "$out/core.attr" || true)"
    b="$(grep "$tag:" "$out/gcc.attr" || true)"
    [ "$a" = "$b" ] || fail abi "$tag differs: Rust '$a', GCC '$b'"
  done

  # --- The linked library, as the firmware links it: compiler_builtins' C
  # math functions made local, so that newlib's are used. ------------------
  cmake -DNM="$BIN/arm-none-eabi-nm" -DOBJCOPY="$BIN/arm-none-eabi-objcopy" \
    -DINPUT="$lib" -DOUTPUT="$out/libtoit_rust_device.a" -P "$VERIFIED/vmverify/staticlib/localize-libm.cmake"
  "$GCC" "${CFLAGS[@]}" -Os -ffunction-sections -fdata-sections \
    --specs=nosys.specs -Wl,--gc-sections -Wl,--emit-relocs -o "$out/check.elf" \
    "$HERE/device_size/main.c" "$out/libtoit_rust_device.a" -lm > "$out/link.log" 2>&1 \
    || { cat "$out/link.log" >&2; exit 1; }
  "$BIN/arm-none-eabi-readelf" -rW "$out/check.elf" > "$out/relocs.txt"
  "$BIN/arm-none-eabi-nm" -C "$out/check.elf" > "$out/symbols.txt"
  "$BIN/arm-none-eabi-objdump" -d --no-show-raw-insn -C "$out/check.elf" > "$out/check.dis"
  # Rust functions: the core's object and compiler_builtins (not newlib, not
  # the C stubs).
  "$BIN/arm-none-eabi-nm" --defined-only "$core_obj" "$out"/obj/compiler_builtins-*.o 2>/dev/null \
    | awk '$2 ~ /^[TtWw]$/ {print $3}' | sort -u > "$out/rust-functions.txt"

  movw="$(awk '$3 ~ /MOVW|MOVT/' "$out/relocs.txt" | wc -l)"
  [ "$movw" = 0 ] || { awk '$3 ~ /MOVW|MOVT/' "$out/relocs.txt" | head -5; fail movw "$movw movw/movt relocations linked"; }

  awk 'NR == FNR { rust[$1] = 1; next }
       /^[0-9a-f]+ <.*>:$/ { fn = substr($2, 2, length($2) - 3); next }
       fn in rust && $2 ~ /^v[a-z]/ { print fn ": " $0 }' \
    "$out/rust-functions.txt" "$out/check.dis" > "$out/fpu.txt" || true
  [ ! -s "$out/fpu.txt" ] || { head -5 "$out/fpu.txt"; fail fpu "$(wc -l < "$out/fpu.txt") VFP/NEON instructions in Rust code"; }

  if grep -E " (__atomic_|__sync_)" "$out/symbols.txt" > "$out/atomics.txt"; then
    cat "$out/atomics.txt"; fail atomics "atomic helpers linked"
  fi
  exclusive="$(grep -c -E $'\t(ldrex|strex)' "$out/check.dis" || true)"

  # Largest frames: `sub sp, #N` (and sub.w) in the prologue of each function.
  awk '/^[0-9a-f]+ <.*>:$/ { fn = $2; seen = 0; next }
       !seen && $2 ~ /^sub(\.w)?$/ && $3 ~ /^sp,/ {
         n = $0; sub(/.*#/, "", n); sub(/[^0-9].*/, "", n); print n + 0, fn; seen = 1 }' \
    "$out/check.dis" | sort -rn | head -5 > "$out/frames.txt"

  if [ "$failed" = 0 ]; then
    echo "thumb codegen ok at opt-level $opt, $loop loop: v7-M Thumb-2, soft float, no movw/movt relocations, no atomic helpers ($exclusive ldrex/strex linked); largest frames:"
    sed 's/^/  /' "$out/frames.txt"
  fi
done
done
exit $failed
