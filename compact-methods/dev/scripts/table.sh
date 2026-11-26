#!/usr/bin/env bash
# Size row per build in bins/: toit.bin, the Rust library (esp_idf_size by
# archive), IRAM text, the 32-bit system image (with this SDK's writer).
# Usage: table.sh TARGET-CONFIG...
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a3d099a7d850ef2fb
A=/home/flo/work/opentoit-sandbox-artifacts/compact-methods/dev
for tc in "$@"; do
  D=$A/bins/$tc
  arch=xtensa
  case $tc in esp32c*) arch=riscv ;; esac
  bash "$A/scripts/size.sh" "$D" "$arch" > /dev/null 2>&1
  rust=$(awk '$1 ~ /libtoit_rust/ { print $NF }' "$D/size-archives.txt")
  iram=$(awk '$1 == ".iram0.text" { print $2 }' "$D/sections.txt")
  "$WT/build/host/sdk/bin/toit" tool snapshot-to-image -m32 --format=binary -o "$D/system.image" "$D/system.snapshot" > /dev/null
  echo "$tc toit.bin $(stat -c %s "$D/toit.bin") rust ${rust:-0} iram $iram system-image $(stat -c %s "$D/system.image")"
done
