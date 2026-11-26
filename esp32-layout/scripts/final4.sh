#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: the board work for the final f2 with the verifier group
# aligned (suffix fin4): untrusted installs at the four pads, speed (bench
# + perf) at the four pads two at a time, and the device suite (b1).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
cd "$A" || exit 1
w() { until [ -f "bins/esp32-$1/sections.txt" ]; do sleep 15; done; }
s() { bash scripts/session.sh "$1" esp32 r1 "$2"; }
bash scripts/pad-installs.sh fin4 > logs/pad-installs-fin4.txt 2>&1
echo "installs done"
w f2-fin4; w f2-p2400-fin4
s b2 f2-fin4 & s b1 f2-p2400-fin4; wait
w f2-p6272-fin4; w f2-p11104-fin4
s b2 f2-p6272-fin4 & s b1 f2-p11104-fin4; wait
echo "speed done"
[ -f env/esp32-f2-fin4-suite.envelope ] || bash scripts/mkenvs.sh esp32 f2-fin4 suite > /dev/null
bash scripts/hwrun.sh b1 esp32-f2-fin4-suite b1-f2-fin4-suite 900 --test-partitions > /dev/null 2>&1
grep -a -c "^SUITE" logs/b1-f2-fin4-suite.txt
echo "final4 done"
