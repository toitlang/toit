#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: board 1 after its 2-hour soak: the final build (fin3)'s
# verification time and install profile, bench/perf sessions, memprobe,
# then a 1-hour one-worker soak of the final build.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A"
bash scripts/hwrun.sh b1 esp32-f2time-fin3-install b1-f2time-fin3-install 900 --test-partitions --wifi > /dev/null 2>&1
echo "time install: $(grep -a -c 'install-trace\] acc' logs/b1-f2time-fin3-install.txt) accepted"
bash scripts/hwrun.sh b1 esp32-f2trace-fin3-install b1-f2trace-fin3-install 900 --test-partitions --wifi > /dev/null 2>&1
echo "trace install: $(grep -a -c 'install-trace\] heap' logs/b1-f2trace-fin3-install.txt) traced"
bash scripts/session.sh b1 esp32 r3 f2-fin3
STOP="MP done|Guru Meditation|abort\(\)|Backtrace:" bash scripts/hwrun.sh b1 esp32-f2-fin3-memprobe b1-f2-fin3-memprobe-r3 1500 --test-partitions > /dev/null 2>&1
echo "memprobe: $(grep -a -c '^MP ' logs/b1-f2-fin3-memprobe-r3.txt) MP lines"
bash scripts/soak.sh b1 esp32-f2-fin3-soakd b1-f2-fin3-soak 3700 > logs/soak-b1-f2-fin3.summary 2>&1
echo "fin3 soak done"
