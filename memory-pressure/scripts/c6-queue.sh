#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# measure-3's ESP32-C6 speed sessions (bench + perf envelopes): the
# unpadded f1 and f2 builds three times (interleaved), then PAD=2400 and
# PAD=6272 once each. Waits for each build.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A" || exit 1
wait_bin() { until [ -f "$A/bins/esp32c6-$1/sections.txt" ]; do sleep 15; done; }
RUNS=${RUNS:-":r1 :r2 :r3 -p2400:r1 -p6272:r1"}
for spec in $RUNS; do
  IFS=: read -r s r <<< "$spec"
  wait_bin "f1$s"; wait_bin "f2$s"
  bash scripts/session.sh c6 esp32c6 "$r" "f1$s" "f2$s"
done
echo "c6 queue done"
