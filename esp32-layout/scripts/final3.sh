#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: the final board work, waiting for each build:
#   speed (bench + perf) of f1 and f2 (suffix fin3) at the four code
#   pads, in parallel on the two boards, boards alternating per pad;

#   untrusted installs of f2time-fin3 at the four pads (two at a time);
#   the data-side pads (RPAD 4096, 9000) of the final and the base
#   configuration, f1 and f2;
#   the device suite of the final f2 (b1).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
cd "$A" || exit 1
w() { until [ -f "bins/esp32-$1/sections.txt" ]; do sleep 15; done; }
s() { bash scripts/session.sh "$1" esp32 r1 "$2"; }
pair() {  # board-for-first first second
  local b1=$1 b2=b2; [ "$1" = b2 ] && b2=b1
  w "$2"; w "$3"
  s "$b1" "$2" & s "$b2" "$3"; wait
}
pair b1 f1-fin3 f2-fin3
pair b2 f1-p2400-fin3 f2-p2400-fin3
pair b1 f1-p6272-fin3 f2-p6272-fin3
pair b2 f1-p11104-fin3 f2-p11104-fin3
echo "speed done"
bash scripts/pad-installs.sh fin3 > logs/pad-installs-fin3.txt 2>&1
echo "installs done"
pair b1 f1-r4096-fin3 f2-r4096-fin3
pair b2 f1-r9000-fin3 f2-r9000-fin3
pair b1 f1-r4096-base2 f2-r4096-base2
pair b2 f1-r9000-base2 f2-r9000-base2
echo "data pads done"
[ -f env/esp32-f2-fin3-suite.envelope ] || bash scripts/mkenvs.sh esp32 f2-fin3 suite > /dev/null
bash scripts/hwrun.sh b1 esp32-f2-fin3-suite b1-f2-fin3-suite 900 --test-partitions > /dev/null 2>&1
grep -a -c "^SUITE" logs/b1-f2-fin3-suite.txt
echo "final2 done"
