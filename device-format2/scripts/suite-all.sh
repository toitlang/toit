#!/usr/bin/env bash
# Builds the suite envelopes of the esp32 configurations and runs them in
# parallel under QEMU (-icount shift=0), then prints the comparable lines
# ("SUITE ...") of each and their differences against f1.
# Usage: suite-all.sh TAG [CONFIGS...]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/device-format2
TAG=$1
shift
CONFIGS=${*:-f1 f2cxx f2}
pids=()
for c in $CONFIGS; do
  format=2
  [ "$c" = f1 ] && format=1
  env=$A/qemu/env/esp32-$c-suite.envelope
  bash "$A/scripts/suite-envelope.sh" "$A/bins/esp32-$c/firmware.envelope" "$env" "$format" > "$A/qemu/env/esp32-$c-suite.log" 2>&1 || { echo "envelope $c failed"; cat "$A/qemu/env/esp32-$c-suite.log"; continue; }
  QEMU_EXTRA="-icount shift=0" bash "$A/scripts/qemu-run.sh" esp32 "$env" "$A/qemu/run-$c-$TAG" 2400 "SUITE deep sleep|Guru Meditation|abort\(\)|Potential dead" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
for c in $CONFIGS; do
  grep -a -E "^SUITE" "$A/qemu/run-$c-$TAG/serial.txt" > "$A/qemu/run-$c-$TAG/suite.txt"
  grep -a -E "^(TIME|MEM)" "$A/qemu/run-$c-$TAG/serial.txt" > "$A/qemu/run-$c-$TAG/measure.txt"
  echo "== $c: $(wc -l < "$A/qemu/run-$c-$TAG/suite.txt") SUITE lines, $(cat "$A/qemu/run-$c-$TAG/wall.txt")"
done
for c in $CONFIGS; do
  [ "$c" = f1 ] && continue
  echo "== diff f1 $c"
  diff "$A/qemu/run-f1-$TAG/suite.txt" "$A/qemu/run-$c-$TAG/suite.txt"
done
