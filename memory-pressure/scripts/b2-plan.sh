#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-final: board 2 after its f1 soak: the stuck-worker reproduction on
# the device (f2, f1), free heap with WiFi on f1 (hwinstall), the data-pad
# sessions of f2 (RPAD 4096, 9000), then the over-capacity f2 soak (two
# workers, 40 minutes).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A" || exit 1
until grep -q "soak: done" logs/soak-b2.run 2> /dev/null; do sleep 20; done
sleep 10
STOP="SUITE done|Guru Meditation|abort\(\)|Backtrace:" bash scripts/hwrun.sh b2 esp32-f2-fin-stuck b2-f2-stuck 240 --test-partitions > /dev/null 2>&1
echo "stuck f2: $(grep -a RESULT logs/b2-f2-stuck.txt)"
STOP="SUITE done|Guru Meditation|abort\(\)|Backtrace:" bash scripts/hwrun.sh b2 esp32-f1-fin-stuck b2-f1-stuck 240 --test-partitions > /dev/null 2>&1
echo "stuck f1: $(grep -a RESULT logs/b2-f1-stuck.txt)"
bash scripts/hwrun.sh b2 esp32-f1-fin-install b2-f1-fin-install 600 --test-partitions --wifi > /dev/null 2>&1
echo "f1 install: $(grep -a 'MEM wifi-up' logs/b2-f1-fin-install.txt)"
for r in r4096 r9000; do
  until [ -f "bins/esp32-f2-$r-fin/sections.txt" ]; do sleep 15; done
  bash scripts/session.sh b2 esp32 r1 "f2-$r-fin"
done
bash scripts/soak.sh b2 esp32-f2-fin-soak2 b2-f2-soak2-overcap 2400 > logs/soak-b2-overcap.run 2>&1
echo "b2 plan done"
