#!/usr/bin/env bash
# ESP32-C6 firmware without the core and with the core at opt 3, s and z;
# prints the section sizes. Usage: fw-all.sh [VARIANT...] (default: all)
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a9365a74954333c15
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WT"
SIZE=$(ls -d "$HOME"/.espressif/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin)/riscv32-esp-elf-size
NM=$(dirname "$SIZE")/riscv32-esp-elf-nm
VARIANTS=("base" "core3 core 3" "cores core s" "corez core z")
[ $# -gt 0 ] && VARIANTS=("$@")
for v in "${VARIANTS[@]}"; do
  set -- $v
  "$HERE/esp32c6.sh" "$@" > "build/esp32c6-$1.log" 2>&1 || { echo "$1 FAILED"; tail -5 "build/esp32c6-$1.log"; continue; }
  echo "== $1: toit.bin $(stat -c %s build/esp32c6-$1/toit.bin)"
  "$SIZE" -A "build/esp32c6-$1/toit.elf" | grep -E "^\.(iram0\.text|dram0\.data|dram0\.bss|flash\.text|flash\.rodata) "
  "$NM" -S "build/esp32c6-$1/toit.elf" | grep -E " toit_v2_run$|run_loop|_ZN4toit11Interpreter3runEv$|toit_vmverify_verify$" || true
done
