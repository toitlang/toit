#!/usr/bin/env bash
# Usage: disfn.sh <object> <function>
# Disassembles one function (Xtensa or RISC-V, chosen by the file name
# prefix xt-/rv-) without relocation lines.
set -euo pipefail
obj=$1
fn=$2
case $(basename "$obj") in
  xt-*) OD=$HOME/.espressif/tools/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32-elf-objdump ;;
  *) OD=$HOME/.espressif/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin/riscv32-esp-elf-objdump ;;
esac
"$OD" -d --disassemble="$fn" "$obj" | sed -n "/<$fn>:/,\$p" | grep -v '^$'
