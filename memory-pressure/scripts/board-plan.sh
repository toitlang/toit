#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-final: the board work after the speed sessions:
#   untrusted installs of f2time-fin at pads 0, 2400, 6272 (both boards);
#   b1: the device suite (f2), then memprobe f2;  b2: memprobe f1, then
#   the OTA scenarios (s1 s3 s4 s5 ep).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A" || exit 1
until grep -q "speed queue done" logs/speed-queue.log; do sleep 20; done
bash scripts/pad-installs.sh fin "0 2400 6272" > logs/pad-installs-fin.txt 2>&1
echo "installs done"
(
  bash scripts/hwrun.sh b1 esp32-f2-fin-suite b1-f2-fin-suite 900 --test-partitions > /dev/null 2>&1
  echo "suite: $(grep -a -c '^SUITE' logs/b1-f2-fin-suite.txt) SUITE lines"
  STOP="MP done|Guru Meditation|abort\(\)|Backtrace:" bash scripts/hwrun.sh b1 esp32-f2-fin-memprobe b1-f2-fin-memprobe 1500 --test-partitions > /dev/null 2>&1
  echo "memprobe f2: $(grep -a -c '^MP ' logs/b1-f2-fin-memprobe.txt) MP lines"
) &
(
  STOP="MP done|Guru Meditation|abort\(\)|Backtrace:" bash scripts/hwrun.sh b2 esp32-f1-fin-memprobe b2-f1-fin-memprobe 900 --test-partitions > /dev/null 2>&1
  echo "memprobe f1: $(grep -a -c '^MP ' logs/b2-f1-fin-memprobe.txt) MP lines"
  until [ -f bins/esp32-f2-ep/sections.txt ]; do sleep 15; done
  [ -f env/esp32-f2-ep-otabep.envelope ] || bash scripts/mkenvs.sh esp32 f2-ep otabep
  bash scripts/ota-final.sh b2 > logs/ota-final-b2.txt 2>&1
  echo "ota done"
) &
wait
echo "board plan done"
