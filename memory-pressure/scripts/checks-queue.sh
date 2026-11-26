#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# measure-3's non-speed device runs, after the speed queues:
#   b1: f2 suite; untrusted installs with WiFi (product f2, time-only trace f2time)
#   b2: driver-error check (f1, f2, f2 without TOIT_SILENT_IDF_CHECKS);
#       exit-code error path (uncaught, 90 s); installs f2/f2time with WiFi
#   c6: driver-error check (f1, f2, f2prev); suite; uncaught; installs f2/f2time
# The C6 gets WiFi credentials for its installs: it is erased afterwards
# (final flash with --erase, see the README).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A" || exit 1
run() { bash scripts/hwrun.sh "$@" > /dev/null 2>&1; echo "ran $2 -> $3: $(grep -a -c '^SUITE\|^TIME' "logs/$3.txt") SUITE/TIME lines"; }
esp32_b1() {
  run b1 esp32-f2-suite b1-f2-suite 900 --test-partitions
  run b1 esp32-f2-install b1-f2-install 900 --test-partitions --wifi
  run b1 esp32-f2time-install b1-f2time-install 900 --test-partitions --wifi
}
esp32_b2() {
  for c in f1 f2 f2prev; do run b2 esp32-$c-drverr b2-$c-drverr 120 --test-partitions; done
  STOP=never run b2 esp32-f2-uncaught b2-f2-uncaught 90 --test-partitions
  run b2 esp32-f2-install b2-f2-install 900 --test-partitions --wifi
  run b2 esp32-f2time-install b2-f2time-install 900 --test-partitions --wifi
}
c6() {
  for c in f1 f2 f2prev; do run c6 esp32c6-$c-drverr c6-$c-drverr 120; done
  run c6 esp32c6-f2-suite c6-f2-suite 900 --test-partitions
  STOP=never run c6 esp32c6-f2-uncaught c6-f2-uncaught 90
  run c6 esp32c6-f2-install c6-f2-install 900 --test-partitions --wifi
  run c6 esp32c6-f2time-install c6-f2time-install 900 --test-partitions --wifi
}
for part in ${*:-esp32_b1 esp32_b2 c6}; do "$part" & done
wait
echo "checks queue done"
