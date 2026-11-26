#!/usr/bin/env bash
# Size table of the firmware builds in bins/ (after fw-all.sh): toit.bin,
# sections, the Rust library and the C++ interpreter objects (esp_idf_size
# on the map file), the system snapshot and its 32-bit image.
# Usage: sizes-all.sh TARGET [CONFIGS...]
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a5fbf012570cfb044}
A=/home/flo/work/opentoit-sandbox-artifacts/device-format2
TOIT=$WT/build/host/sdk/bin/toit
TARGET=$1
shift
CONFIGS=${*:-f1 f2cxx f2}
arch=riscv
case $TARGET in esp32|esp32s2|esp32s3) arch=xtensa ;; esac
printf "%-8s %9s %8s %8s %8s %9s %8s %8s %8s %8s %8s %8s\n" config toit.bin iram dram.d dram.bss flash.text rodata rust vm interp_run m_entries sys.snap sys.img
for c in $CONFIGS; do
  D=$A/bins/$TARGET-$c
  bash "$A/scripts/size.sh" "$D" "$arch" > /dev/null 2>&1
  sec() { awk -v s="$1" '$1 == s { print $2 }' "$D/sections.txt"; }
  arch_total() { awk -v n="$1" '$1 == n { print $NF }' "$D/size-archives.txt"; }
  file_total() { awk -v n="$1" '$1 == n { print $NF }' "$D/size-files.txt"; }
  "$TOIT" tool snapshot-to-image -m32 --format=binary -o "$D/system.image" "$D/system.snapshot" > /dev/null 2>&1
  printf "%-8s %9s %8s %8s %8s %9s %8s %8s %8s %8s %8s %8s\n" "$c" "$(stat -c %s "$D/toit.bin")" \
    "$(sec .iram0.text)" "$(sec .dram0.data)" "$(sec .dram0.bss)" "$(sec .flash.text)" "$(sec .flash.rodata)" \
    "$(arch_total libtoit_rust.a)" "$(arch_total libtoit_vm.a)" "$(file_total interpreter_run.cc.obj)" \
    "$(file_total method_entries.cc.obj)" "$(stat -c %s "$D/system.snapshot")" "$(stat -c %s "$D/system.image")"
done
