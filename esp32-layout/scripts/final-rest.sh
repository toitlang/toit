#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: the board work after the final speed sessions and installs:
# the data-side layout check (RPAD builds of the final and the base
# configuration, f1 and f2, in parallel on the two boards) and the device
# suite of the final f2 (b1, test partitions).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
cd "$A" || exit 1
w() { until [ -f "bins/esp32-$1/sections.txt" ]; do sleep 15; done; }
pair() {  # f1-build f2-build
  w "$1"; w "$2"
  bash scripts/session.sh b1 esp32 r1 "$1" &
  bash scripts/session.sh b2 esp32 r1 "$2"
  wait
}
pair f1-r4096-fin f2-r4096-fin
pair f1-r9000-fin f2-r9000-fin
w f2-fin
[ -f env/esp32-f2-fin-suite.envelope ] || bash scripts/mkenvs.sh esp32 f2-fin suite > /dev/null
bash scripts/hwrun.sh b1 esp32-f2-fin-suite b1-f2-fin-suite 900 --test-partitions > /dev/null 2>&1 &
pair_base() {
  w "$1"; w "$2"
  bash scripts/session.sh b2 esp32 r1 "$1"
  bash scripts/session.sh b2 esp32 r1 "$2"
}
pair_base f1-r4096-base2 f2-r4096-base2
wait
pair f1-r9000-base2 f2-r9000-base2
echo "final rest done"
