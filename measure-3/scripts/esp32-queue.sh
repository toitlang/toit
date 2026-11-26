#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# measure-3's classic ESP32 speed sessions (bench + perf envelopes), f1 and
# f2 in parallel on the two rig boards, the boards swapped between runs so
# that neither format is measured on one board only:
#   unpadded build: r1 (f1 b1, f2 b2), r2 (f1 b2, f2 b1), r3 (as r1)
#   PAD=2400 (as r1), 6272 (as r2), 11104 (as r1), one session each.
# Waits for each build (bins/esp32-<config>/sections.txt).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/measure-3
cd "$A" || exit 1
wait_bin() { until [ -f "$A/bins/esp32-$1/sections.txt" ]; do sleep 15; done; }
pair() {  # suffix run swapped
  local s=$1 r=$2 sw=$3 bf1=b1 bf2=b2
  [ "$sw" = 1 ] && { bf1=b2; bf2=b1; }
  wait_bin "f1$s"; wait_bin "f2$s"
  bash scripts/session.sh $bf1 esp32 "$r" "f1$s" &
  bash scripts/session.sh $bf2 esp32 "$r" "f2$s"
  wait
}
RUNS=${RUNS:-":r1:0 :r2:1 :r3:0 -p2400:r1:0 -p6272:r1:1 -p11104:r1:0"}
for spec in $RUNS; do
  IFS=: read -r s r sw <<< "$spec"
  pair "$s" "$r" "$sw"
done
echo "esp32 queue done"
