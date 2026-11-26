#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Disassembles step::run_loop of a RISC-V (C6) firmware ELF.
# Usage: runloop-dis-rv.sh ELF OUT
R=/home/flo/.espressif/tools/riscv32-esp-elf/esp-15.2.0_20250929/riscv32-esp-elf/bin
read -r addr size _ name < <("$R/riscv32-esp-elf-nm" -S "$1" | grep "4step8run_loop$")
start=$((16#$addr)); end=$((start + 16#$size))
"$R/riscv32-esp-elf-objdump" -d --no-show-raw-insn --start-address=$start --stop-address=$end "$1" > "$2"
wc -l "$2"
