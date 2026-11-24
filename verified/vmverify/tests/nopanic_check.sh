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

# The device library has no panic paths (README.md, "No panics on
# devices"): builds verified/vmverify as devices link it (riscv32imac,
# no_std, the `device-runtime` feature, Cargo profile `device`), links it
# into the minimal executable of device_size.sh (device_size/main.c: the
# core's run loop and the verifier's entry point) with --gc-sections, and
# fails if any symbol of the panic or formatting machinery survives:
# core::panicking, core::fmt, the panic handler (rust_begin_unwind and the
# VM's toit_vmverify_panic it calls), slice index failures, unwrap/expect
# failures and the infallible allocation's error paths (handle_alloc_error,
# raw_vec::handle_error, capacity_overflow). Allocation failures must reject
# (OUT_OF_MEMORY), out-of-range accesses must be proven impossible or
# rejected.
#
# Both configurations of the core's run loop are checked: whole and split
# (feature `split-loop`).
#
# Usage: nopanic_check.sh [OPT-LEVEL...]   (default: 3, the configured
#   level of the core; the verifier is at z whatever the core's)
# Needs the ESP-IDF RISC-V toolchain (riscv32-esp-elf-gcc, found in
# ~/.espressif/tools or on the PATH) and the riscv32imac Rust target.
#   NOPANIC_ARCH=arm: the EC618 instead (thumbv7m-none-eabi, Cortex-M3),
#   linked with the SDK-pinned GNU Arm toolchain (EC618_GCC_PATH or xmake's
#   gnu_rm package, else arm-none-eabi-gcc on the PATH).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIED="$(cd "$HERE/../.." && pwd)"
ARCH="${NOPANIC_ARCH:-riscv}"
LEVELS=("$@")
if [ ${#LEVELS[@]} -eq 0 ]; then LEVELS=(3); fi

case "$ARCH" in
  riscv)
    WORK="$VERIFIED/../build/vmverify-nopanic"
    TARGET=riscv32imac-unknown-none-elf
    PREFIX=riscv32-esp-elf
    CFLAGS=(-march=rv32imac_zicsr_zifencei -mabi=ilp32)
    GCC="$(command -v riscv32-esp-elf-gcc || true)"
    if [ -z "$GCC" ]; then
      GCC="$(ls -d "$HOME"/.espressif/tools/riscv32-esp-elf/esp-1[0-9]*/riscv32-esp-elf/bin/riscv32-esp-elf-gcc 2>/dev/null | sort -V | tail -1)"
    fi
    ;;
  arm)
    WORK="$VERIFIED/../build/vmverify-nopanic-arm"
    TARGET=thumbv7m-none-eabi
    PREFIX=arm-none-eabi
    CFLAGS=(-mcpu=cortex-m3 -mthumb)
    GCC="$(ls -d "${EC618_GCC_PATH:-/nonexistent}/bin/arm-none-eabi-gcc" \
        "$HOME"/.xmake/packages/g/gnu_rm/*/*/bin/arm-none-eabi-gcc 2>/dev/null | head -1 || true)"
    [ -n "$GCC" ] || GCC="$(command -v arm-none-eabi-gcc || true)"
    ;;
  *) echo "unknown NOPANIC_ARCH: $ARCH" >&2; exit 2 ;;
esac
[ -x "$GCC" ] || { echo "$PREFIX-gcc not found" >&2; exit 1; }
NM="$(dirname "$GCC")/$PREFIX-nm"

# Demangled names (nm -C) of the machinery that must not be linked.
FORBIDDEN='core::panicking|core::fmt|rust_begin_unwind|toit_vmverify_panic|panic_bounds_check|slice_index_fail|slice_start_index|slice_end_index|unwrap_failed|expect_failed|handle_alloc_error|alloc_error_handler|raw_vec::handle_error|capacity_overflow|core::result::unwrap|core::option::unwrap|core::option::expect'

failed=0
# Both configurations of the run loop: whole (the default) and split
# (feature `split-loop`, Kconfig TOIT_VERIFIED_CORE_SPLIT_LOOP).
for loop in whole split; do
  features=device-runtime
  [ "$loop" = split ] && features=device-runtime,split-loop
  for opt in "${LEVELS[@]}"; do
    out="$WORK/opt$opt-$loop"
    mkdir -p "$out"
    echo "== device library, opt-level $opt, $loop loop ($TARGET)"
    (cd "$VERIFIED/vmverify/staticlib" && CARGO_PROFILE_DEVICE_OPT_LEVEL="$opt" cargo build --quiet --profile device --lib \
        --no-default-features --features "$features" --target "$TARGET" --target-dir "$out/target")
    "$GCC" "${CFLAGS[@]}" -Os -ffunction-sections -fdata-sections \
      --specs=nosys.specs -Wl,--gc-sections -o "$out/check.elf" \
      "$HERE/device_size/main.c" "$out/target/$TARGET/device/libtoit_rust.a" -lm > "$out/link.log" 2>&1 \
      || { cat "$out/link.log" >&2; exit 1; }
    "$NM" -C "$out/check.elf" > "$out/symbols.txt"
    if grep -E "$FORBIDDEN" "$out/symbols.txt" > "$out/forbidden.txt"; then
      echo "FAIL: panic or formatting machinery linked at opt-level $opt, $loop loop:"
      cat "$out/forbidden.txt"
      failed=1
    else
      echo "no panic paths at opt-level $opt, $loop loop, $TARGET ($(wc -l < "$out/symbols.txt") symbols linked)"
    fi
  done
done
exit $failed
