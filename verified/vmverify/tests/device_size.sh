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

# Size of the device Rust library (verified core, primitives, verifier) as
# linked into firmware: builds the VM's static library (verified/vmverify/
# staticlib: no_std, device runtime, Cargo profile `device`: fat LTO,
# panic = abort) for riscv32imac (or the classic ESP32) at the given
# opt-level, links it into a minimal executable (device_size/main.c: the
# core's run loop and the verifier's entry point, the C++ helpers stubbed)
# with --gc-sections, and reports text + rodata by component
# (verified/tools/device_size.toit on the linked symbols).
#
# Usage: device_size.sh OPT-LEVEL [notaildup] [OUT-DIR]
#   OPT-LEVEL: 3, s or z. notaildup: without the -tail-dup-size flag of
#   verified/vmverify/.cargo/config.toml.
#   DEVICE_SIZE_ARCH=xtensa: the classic ESP32 (xtensa-esp32-none-elf with
#   the Toit Xtensa toolchain, `cargo +toit-esp -Zbuild-std`, ESP-IDF's
#   xtensa GCC; docs/xtensa-rust-toolchain.md). DEVICE_SIZE_ARCH=arm: the EC618
#   (thumbv7m-none-eabi, Cortex-M3; the SDK-pinned GNU Arm toolchain from
#   EC618_GCC_PATH or xmake's gnu_rm package, else arm-none-eabi-gcc on the
#   PATH). DEVICE_SIZE_LTO=false: without LTO (one object per crate, as
#   before the staticlib package).
# Needs the ESP-IDF RISC-V toolchain (riscv32-esp-elf-gcc, found in
# ~/.espressif/tools or on the PATH) and the riscv32imac Rust target (or,
# for Xtensa, the toit-esp toolchain and ESP-IDF's xtensa-esp32-elf-gcc; for
# arm, the thumbv7m-none-eabi Rust target).

set -euo pipefail
trap 'echo "device_size.sh: failed at line $LINENO" >&2' ERR

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIED="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$VERIFIED/.." && pwd)"
OPT="${1:?opt-level}"
TAILDUP=1
if [ "${2:-}" = notaildup ]; then TAILDUP=0; shift; fi
# The vmverify features (default: the device configuration, without the
# inference and the checked loop), e.g. DEVICE_SIZE_FEATURES=device-runtime,infer;
# DEVICE_SIZE_SUFFIX is appended to the output directory's name.
FEATURES="${DEVICE_SIZE_FEATURES:-device-runtime}"
ARCH="${DEVICE_SIZE_ARCH:-riscv}"
NAME="$(case "$ARCH" in xtensa|arm) echo "$ARCH-" ;; esac)opt$OPT$([ "$TAILDUP" = 0 ] && echo -notaildup || true)${DEVICE_SIZE_SUFFIX:-}"
OUT="${2:-$REPO/build/device-size}/$NAME"
mkdir -p "$OUT"

case "$ARCH" in
  riscv)
    TARGET=riscv32imac-unknown-none-elf
    PREFIX=riscv32-esp-elf
    CFLAGS=(-march=rv32imac_zicsr_zifencei -mabi=ilp32)
    DEFAULT_CARGO_ARGS=""
    ;;
  xtensa)
    TARGET=xtensa-esp32-none-elf
    PREFIX=xtensa-esp32-elf
    CFLAGS=(-mlongcalls)
    DEFAULT_CARGO_ARGS="+toit-esp -Zbuild-std=core,alloc"
    ;;
  arm)
    TARGET=thumbv7m-none-eabi
    PREFIX=arm-none-eabi
    CFLAGS=(-mcpu=cortex-m3 -mthumb)
    DEFAULT_CARGO_ARGS=""
    ;;
  *) echo "unknown DEVICE_SIZE_ARCH: $ARCH" >&2; exit 2 ;;
esac
GCC=""
if [ "$ARCH" = arm ]; then
  # The EC618 SDK's toolchain (Makefile EC618_GCC_PATH), as the firmware.
  GCC="$(ls -d "${EC618_GCC_PATH:-/nonexistent}/bin/arm-none-eabi-gcc" \
      "$HOME"/.xmake/packages/g/gnu_rm/*/*/bin/arm-none-eabi-gcc 2>/dev/null | head -1 || true)"
fi
[ -n "$GCC" ] || GCC="$(command -v $PREFIX-gcc || true)"
if [ -z "$GCC" ]; then
  GCC="$(ls -d "$HOME"/.espressif/tools/*-esp-elf/esp-1[0-9]*/*-esp-elf/bin/$PREFIX-gcc 2>/dev/null | sort -V | tail -1)"
fi
[ -x "$GCC" ] || { echo "$PREFIX-gcc not found" >&2; exit 1; }
BIN="$(dirname "$GCC")"

ENVS=(CARGO_PROFILE_DEVICE_OPT_LEVEL="$OPT")
if [ "$TAILDUP" = 0 ]; then ENVS+=(RUSTFLAGS=""); fi
if [ -n "${DEVICE_SIZE_LTO:-}" ]; then ENVS+=(CARGO_PROFILE_DEVICE_LTO="$DEVICE_SIZE_LTO"); fi
# Experiments: DEVICE_SIZE_TOOLCHAIN (e.g. +nightly) and DEVICE_SIZE_CARGO_ARGS
# (e.g. -Zbuild-std=core,alloc) are passed to cargo, DEVICE_SIZE_RUSTFLAGS
# replaces the rustflags of .cargo/config.toml.
read -r -a CARGO_ARGS <<< "${DEVICE_SIZE_TOOLCHAIN:-} ${DEVICE_SIZE_CARGO_ARGS:-$DEFAULT_CARGO_ARGS}"
if [ -n "${DEVICE_SIZE_RUSTFLAGS:-}" ]; then ENVS+=(RUSTFLAGS="$DEVICE_SIZE_RUSTFLAGS"); fi
(cd "$VERIFIED/vmverify/staticlib" && env "${ENVS[@]}" PATH="$BIN:$PATH" cargo ${CARGO_ARGS[@]+"${CARGO_ARGS[@]}"} build --quiet --profile device --lib \
    --no-default-features --features "$FEATURES" --target "$TARGET" --target-dir "$OUT/target")
LIB="$OUT/target/$TARGET/device/libtoit_rust.a"

"$GCC" "${CFLAGS[@]}" -Os -ffunction-sections -fdata-sections \
  --specs=nosys.specs -Wl,--gc-sections -Wl,-Map="$OUT/size.map" -o "$OUT/size.elf" \
  "$HERE/device_size/main.c" "$LIB" -lm
"$BIN/$PREFIX-size" -A "$OUT/size.elf" > "$OUT/sections.txt"
"$BIN/$PREFIX-nm" -S -C --size-sort "$OUT/size.elf" > "$OUT/symbols.txt"
# The C side alone (stubs, newlib): subtracted from the totals.
"$GCC" "${CFLAGS[@]}" -Os -ffunction-sections -fdata-sections \
  --specs=nosys.specs -Wl,--gc-sections -o "$OUT/empty.elf" \
  -x c - <<'EOF'
volatile int sink;
int main(void) { sink = 0; return 0; }
EOF
"$BIN/$PREFIX-size" -A "$OUT/empty.elf" > "$OUT/empty-sections.txt"
TOIT="${TOIT:-$REPO/build/host/sdk/bin/toit}"
"$TOIT" run "$VERIFIED/tools/device_size.toit" -- --name "$NAME" "$OUT/symbols.txt" "$OUT/sections.txt" "$OUT/empty-sections.txt"
