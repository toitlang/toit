#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: board 1 after its 2-hour soak (replaces b1-final.sh after
# its first step): the final build (fin3)'s install profile, bench/perf,
# the verification time of two code-padded builds of the base and of fin3
# (layout sensitivity), memprobe, then a 30-minute one-worker soak of fin3.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A"
bash scripts/hwrun.sh b1 esp32-f2trace-fin3-install b1-f2trace-fin3-install 900 --test-partitions --wifi > /dev/null 2>&1
echo "trace install: $(grep -a -c 'install-trace\] heap' logs/b1-f2trace-fin3-install.txt) traced"
bash scripts/session.sh b1 esp32 r3 f2-fin3
until [ -f env/esp32-f2time-p6272-base-install.envelope ]; do sleep 10; done
for c in f2time-p2400-base f2time-p2400-fin3 f2time-p6272-base f2time-p6272-fin3; do
  bash scripts/hwrun.sh b1 "esp32-$c-install" "b1-$c-install" 900 --test-partitions --wifi > /dev/null 2>&1
  echo "$c: $(grep -a -c 'install-trace\] acc' "logs/b1-$c-install.txt") accepted"
done
STOP="MP done|Guru Meditation|abort\(\)|Backtrace:" bash scripts/hwrun.sh b1 esp32-f2-fin3-memprobe b1-f2-fin3-memprobe-r3 1500 --test-partitions > /dev/null 2>&1
echo "memprobe: $(grep -a -c '^MP ' logs/b1-f2-fin3-memprobe-r3.txt) MP lines"
bash scripts/soak.sh b1 esp32-f2-fin3-soakd b1-f2-fin3-soak 1800 > logs/soak-b1-f2-fin3.summary 2>&1
echo "fin3 soak done"
