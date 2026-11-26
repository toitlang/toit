#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The largest symbols of a build matching an optional regex.
# Usage: bigsyms.sh BUILD-NAME [REGEX] [COUNT]   (BUILD-NAME: bins/<name>)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed
B=$A/bins/$1
RE=${2:-.}
N=${3:-20}
case $1 in
  esp32c6*|esp32c3*) NM=$HOME/.espressif/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin/riscv32-esp-elf-nm ;;
  *) NM=$HOME/.espressif/tools/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32-elf-nm ;;
esac
"$NM" -S --size-sort -C "$B/toit.elf" | grep -E -- "$RE" | tail -n "$N" | while read -r addr size type name; do
  printf '%8d %s %s %s\n' "$((16#$size))" "$addr" "$type" "$name"
done
