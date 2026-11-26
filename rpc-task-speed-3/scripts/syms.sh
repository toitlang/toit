#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Symbols of a firmware ELF matching a regex, with sizes and the memory they
# are in (iram, dram, flash-text, flash-rodata), and the total size.
# Usage: syms.sh BIN-NAME REGEX [REGION]   (BIN-NAME: bins/<name>/toit.elf;
#   REGION: iram, dram, irom, drom or all)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-3
T=$HOME/.espressif/tools
ELF=$A/bins/$1/toit.elf
RE=$2
REGION=${3:-all}
case $1 in
  esp32c6*|esp32c3*) NM=$(ls "$T"/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin/riscv32-esp-elf-nm) ;;
  esp32s3*) NM=$T/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32s3-elf-nm ;;
  *) NM=$T/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32-elf-nm ;;
esac
"$NM" -S --size-sort -C "$ELF" | awk -v re="$RE" -v region="$REGION" '
  NF >= 4 {
    a = strtonum("0x" $1); s = strtonum("0x" $2)
    name = $4; for (i = 5; i <= NF; i++) name = name " " $i
    if (name !~ re) next
    r = "other"
    if (a >= 0x40080000 && a < 0x400a0000) r = "iram"          # ESP32 IRAM
    else if (a >= 0x40370000 && a < 0x403e0000) r = "iram"     # S3 IRAM
    else if (a >= 0x3ffae000 && a < 0x40000000) r = "dram"     # ESP32 DRAM
    else if (a >= 0x3fc88000 && a < 0x3fd00000) r = "dram"     # S3 DRAM
    else if (a >= 0x40800000 && a < 0x40880000) r = "sram"     # C6 HP SRAM
    else if (a >= 0x400d0000 && a < 0x40400000) r = "irom"     # ESP32 flash text
    else if (a >= 0x42000000 && a < 0x42800000) r = "irom"     # C6/S3 flash text
    else if (a >= 0x3f400000 && a < 0x3f800000) r = "drom"     # ESP32 flash rodata
    else if (a >= 0x3c000000 && a < 0x3c800000) r = "drom"     # S3 flash rodata
    if (region != "all" && r != region) next
    printf "%-6s %7d %s\n", r, s, name
    total += s
  }
  END { printf "total %d\n", total }'
