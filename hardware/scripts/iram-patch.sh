#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# IRAM experiment: renames the sections of the core's run_loop (text and
# literals, optionally its jump table) in a build's libtoit_rust_device.a so
# that ESP-IDF's linker script places them in IRAM (.iram1.*) and DRAM
# (.dram1.*), then relinks the build (fw.sh with the same arguments).
# Usage: iram-patch.sh TARGET NAME [--rodata] -- [SDKCONFIG-LINE...]
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ad2fa912738994022}
A=/home/flo/work/opentoit-sandbox-artifacts/hardware
TARGET=$1
NAME=$2
shift 2
RODATA=0
if [ "${1:-}" = --rodata ]; then RODATA=1; shift; fi
[ "${1:-}" = -- ] && shift
case $TARGET in
  esp32c6) BIN=$HOME/.espressif/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin/riscv32-esp-elf
           TRIPLE=riscv32imac-unknown-none-elf ;;
  *) BIN=$HOME/.espressif/tools/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-$TARGET-elf
     TRIPLE=xtensa-$TARGET-none-elf ;;
esac
LIB=$(ls "$WT/build/$TARGET-$NAME/verified_core/"*/device/libtoit_rust_device.a)
args=()
while read -r sec; do
  case $sec in
    .literal.*) args+=(--rename-section "$sec=.iram1.toit_run_loop.literal") ;;
    .text.*) args+=(--rename-section "$sec=.iram1.toit_run_loop") ;;
    .srodata.*|.rodata.*) [ $RODATA = 1 ] && args+=(--rename-section "$sec=.dram1.toit_run_loop") ;;
  esac
done < <("$BIN-objdump" -h "$LIB" | awk '{print $2}' | grep -E "^\.(literal|text|rodata|srodata)\..*step8run_loop$")
echo "renames: ${args[*]}"
"$BIN-objcopy" "${args[@]}" "$LIB" "$LIB.tmp"
mv "$LIB.tmp" "$LIB"
"$BIN-objdump" -h "$LIB" | grep -E "toit_run_loop" || true
bash "$A/scripts/fw.sh" "$TARGET" "$NAME" "$@"
