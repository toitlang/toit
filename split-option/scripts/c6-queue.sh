#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Layout-perturbed C6 builds (after the ESP32 build queue) and their
# sessions: f1, f2 (whole loop) and f2s (split loop) with two pads each.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/split-option
cd "$A" || exit 1
wait_bin() { until [ -f "$A/bins/esp32c6-$1/sections.txt" ]; do sleep 15; done; }
for p in 2400 6272; do
  wait_bin "f1-p$p"; wait_bin "f2-p$p"; wait_bin "f2s-p$p"
done
for p in 2400 6272; do
  bash scripts/session.sh c6 esp32c6 r1 "f1-p$p" "f2-p$p" "f2s-p$p"
done
echo "c6 queue done"
