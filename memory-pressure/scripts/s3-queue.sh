#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# s3-ota-soak's ESP32-S3 runs on one board (s3a: 2 MB PSRAM, s3b: none),
# all with the test partitions (one 2.75 MB app partition):
#   speed: three sessions of f1 and f2 (bench + perf envelopes), r1 and r3
#          f1 first, r2 f2 first;
#   then:  untrusted installs with WiFi (product f2, time-only trace f2time),
#          the exit-code error path (uncaught, 90 s).
# The board gets the rig's WiFi credentials for the installs; restore.sh
# writes the original flash back at the end of the work.
# Usage: s3-queue.sh BOARD [PARTS...]   (PARTS: speed checks)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A" || exit 1
B=$1
shift
run() { bash scripts/hwrun.sh "$@" > /dev/null 2>&1; echo "ran $2 -> $3: $(grep -a -c '^SUITE\|^TIME\|^BENCH' "logs/$3.txt") SUITE/TIME/BENCH lines"; }
sess() {  # run configs...
  local r=$1; shift
  for c in "$@"; do
    for k in bench perf; do
      run "$B" "esp32s3-$c-$k" "$B-$c-$k-$r" 600 --test-partitions
    done
  done
}
for part in ${*:-speed checks}; do
  case $part in
    speed) sess r1 f1 f2; sess r2 f2 f1; sess r3 f1 f2 ;;
    checks)
      run "$B" esp32s3-f2-install "$B-f2-install" 900 --test-partitions --wifi
      run "$B" esp32s3-f2time-install "$B-f2time-install" 900 --test-partitions --wifi
      STOP=never run "$B" esp32s3-f2-uncaught "$B-f2-uncaught" 90 --test-partitions
      ;;
  esac
done
echo "s3 queue $B done"
