#!/usr/bin/env bash
# Runs progs/bench.toit on an esp32 build under QEMU (-icount shift=0).
# Usage: bench-run.sh CONFIG [FORMAT]
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a5fbf012570cfb044}
A=/home/flo/work/opentoit-sandbox-artifacts/device-format2
TOIT=$WT/build/host/sdk/bin/toit
C=$1
FORMAT=${2:-2}
D=$A/qemu/bench-$C
rm -rf "$D"
mkdir -p "$D"
cp "$A"/qemu/progs/{bench,richards,deltablue,pystone,benchmark}.toit "$D/"
TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/bench.snapshot" "$D/bench.toit" || exit 1
cp "$A/bins/esp32-$C/firmware.envelope" "$D/fw.envelope"
"$TOIT" tool firmware -e "$D/fw.envelope" container install bench "$D/bench.snapshot" || exit 1
QEMU_EXTRA="-icount shift=0" bash "$A/scripts/qemu-run.sh" esp32 "$D/fw.envelope" "$D/run" 1200
grep -a -E "^TIME" "$D/run/serial.txt"
