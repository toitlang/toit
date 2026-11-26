#!/usr/bin/env bash
# Decodes Xtensa/RISC-V addresses of a firmware elf. Usage: a2l.sh ELF ADDR...
set -euo pipefail
ELF=$1
shift
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
if xtensa-esp32-elf-readelf -h "$ELF" 2>/dev/null | grep -q Xtensa; then
  A2L=xtensa-esp32-elf-addr2line
else
  A2L=riscv32-esp-elf-addr2line
fi
"$A2L" -pfiaC -e "$ELF" "$@"
