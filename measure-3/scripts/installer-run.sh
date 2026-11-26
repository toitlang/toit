#!/usr/bin/env bash
# Runs the installer container (progs/installer.toit) with the untrusted
# images of qemu/installer-assets on an esp32 firmware build (typically a
# TOIT_TRACE_INSTALL one) under QEMU (-icount shift=0).
# Usage: installer-run.sh CONFIG TAG [FORMAT]
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a8cbed86ae1ed9653}
A=/home/flo/work/opentoit-sandbox-artifacts/measure-3
TOIT=$WT/build/host/sdk/bin/toit
C=$1
TAG=$2
FORMAT=${3:-2}
D=$A/qemu/installer-$C-$TAG
rm -rf "$D"
mkdir -p "$D"
"$TOIT" tool assets -e "$D/installer.assets" create
for img in "$A"/qemu/installer-assets/*.image; do
  "$TOIT" tool assets -e "$D/installer.assets" add "$(basename "$img" .image)" "$img"
done
TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/installer.snapshot" "$A/progs/suite/installer.toit" || exit 1
cp "$A/bins/esp32-$C/firmware.envelope" "$D/fw.envelope"
"$TOIT" tool firmware -e "$D/fw.envelope" container install --assets "$D/installer.assets" installer "$D/installer.snapshot" || exit 1
QEMU_EXTRA="-icount shift=0" bash "$A/scripts/qemu-run.sh" esp32 "$D/fw.envelope" "$D/run" 7200 "SUITE done|Guru Meditation|abort\(\)|Potential dead"
grep -a -E "^(SUITE|TIME|MEM)|install-trace|verifier:|refused|Guru" "$D/run/serial.txt"
