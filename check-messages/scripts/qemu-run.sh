#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Runs progs/trigger.toit on a firmware build in Espressif's QEMU (classic
# ESP32) and keeps the console output in logs/qemu-<config>.txt.
# Usage: qemu-run.sh CONFIG [SECONDS]   (CONFIG: bins/esp32-<CONFIG>)
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a761e44286b8f7807
A=/home/flo/work/opentoit-sandbox-artifacts/check-messages
TOIT=$WT/build/host/sdk/bin/toit
QEMU=$(ls -d "$HOME"/.espressif/tools/qemu-xtensa/*/qemu/bin | tail -1)/qemu-system-xtensa
C=$1
SECS=${2:-60}
D=$A/bins/esp32-$C
export TMPDIR=$WT/build/tmp
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FMT=2
[[ "$C" == f1* ]] && FMT=1
TOIT_BYTECODE_FORMAT=$FMT "$TOIT" compile --snapshot -o "$T/trigger.snapshot" "$A/progs/trigger.toit"
"$TOIT" tool firmware -e "$D/firmware.envelope" container install -o "$T/t.envelope" trigger "$T/trigger.snapshot"
"$TOIT" tool firmware -e "$T/t.envelope" extract --format=image -o "$T/flash.bin"
timeout "$SECS" "$QEMU" -M esp32 -display none -monitor none -serial "file:$A/logs/qemu-$C.txt" \
  -drive "file=$T/flash.bin,format=raw,if=mtd" -no-reboot || true
grep -a "TRIGGER\|{D1\|E chk\|E (" "$A/logs/qemu-$C.txt" | head -40
