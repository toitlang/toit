#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The layout-perturbed ESP32 sessions: for each pad, waits for its builds,
# then f1 and f2 (whole loop) on board 1 and f2s (split loop) on board 2.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/install-speed
cd "$A" || exit 1
wait_bin() { until [ -f "$A/bins/esp32-$1/sections.txt" ]; do sleep 15; done; }
for p in ${PADS:-2400 6272 11104}; do
  wait_bin "f1-p$p"; wait_bin "f2-p$p"; wait_bin "f2s-p$p"
  bash scripts/session.sh b1 esp32 r1 "f1-p$p" "f2-p$p" &
  bash scripts/session.sh b2 esp32 r1 "f2s-p$p"
  wait
done
echo "esp32 queue done"
