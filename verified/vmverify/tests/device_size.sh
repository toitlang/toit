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
# linked into firmware: builds verified/vmverify for riscv32imac (no_std,
# device runtime, Cargo profile `device`: LTO, panic = abort) at the given
# opt-level, links it into a minimal executable (device_size/main.c: the
# core's run loop and the verifier's entry point, the C++ helpers stubbed)
# with --gc-sections, and reports text + rodata by component
# (verified/tools/device_size.toit on the linked symbols).
#
# Usage: device_size.sh OPT-LEVEL [notaildup] [OUT-DIR]
#   OPT-LEVEL: 3, s or z. notaildup: without the -tail-dup-size flag of
#   verified/vmverify/.cargo/config.toml.
# Needs the ESP-IDF RISC-V toolchain (riscv32-esp-elf-gcc, found in
# ~/.espressif/tools or on the PATH) and the riscv32imac Rust target.

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
NAME="opt$OPT$([ "$TAILDUP" = 0 ] && echo -notaildup || true)${DEVICE_SIZE_SUFFIX:-}"
OUT="${2:-$REPO/build/device-size}/$NAME"
TARGET=riscv32imac-unknown-none-elf
mkdir -p "$OUT"

GCC="$(command -v riscv32-esp-elf-gcc || true)"
if [ -z "$GCC" ]; then
  GCC="$(ls -d "$HOME"/.espressif/tools/riscv32-esp-elf/esp-1[0-9]*/riscv32-esp-elf/bin/riscv32-esp-elf-gcc 2>/dev/null | sort -V | tail -1)"
fi
[ -x "$GCC" ] || { echo "riscv32-esp-elf-gcc not found" >&2; exit 1; }
BIN="$(dirname "$GCC")"

ENVS=(CARGO_PROFILE_DEVICE_OPT_LEVEL="$OPT")
if [ "$TAILDUP" = 0 ]; then ENVS+=(RUSTFLAGS=""); fi
(cd "$VERIFIED/vmverify" && env "${ENVS[@]}" cargo build --quiet --profile device --lib \
    --no-default-features --features "$FEATURES" --target "$TARGET" --target-dir "$OUT/target")
LIB="$OUT/target/$TARGET/device/libtoit_vmverify.a"

"$GCC" -march=rv32imac_zicsr_zifencei -mabi=ilp32 -Os -ffunction-sections -fdata-sections \
  --specs=nosys.specs -Wl,--gc-sections -Wl,-Map="$OUT/size.map" -o "$OUT/size.elf" \
  "$HERE/device_size/main.c" "$LIB" -lm
"$BIN/riscv32-esp-elf-size" -A "$OUT/size.elf" > "$OUT/sections.txt"
"$BIN/riscv32-esp-elf-nm" -S -C --size-sort "$OUT/size.elf" > "$OUT/symbols.txt"
# The C side alone (stubs, newlib): subtracted from the totals.
"$GCC" -march=rv32imac_zicsr_zifencei -mabi=ilp32 -Os -ffunction-sections -fdata-sections \
  --specs=nosys.specs -Wl,--gc-sections -o "$OUT/empty.elf" \
  -x c - <<'EOF'
volatile int sink;
int main(void) { sink = 0; return 0; }
EOF
"$BIN/riscv32-esp-elf-size" -A "$OUT/empty.elf" > "$OUT/empty-sections.txt"
TOIT="${TOIT:-$REPO/build/host/sdk/bin/toit}"
"$TOIT" run "$VERIFIED/tools/device_size.toit" -- --name "$NAME" "$OUT/symbols.txt" "$OUT/sections.txt" "$OUT/empty-sections.txt"
