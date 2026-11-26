#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# liveness: the board plan after the 8-hour soak. Every flash goes through
# soak.sh -> flash.sh -> guard.sh (allow-list and chip check).
#   1. A/B, 40 minutes, concurrently: board 1 base (b1086c16, f2, one
#      worker), board 2 the fixes (f2-fix, one worker).
#   2. Confirmation, concurrently: board 1 the fixes, one worker, 2 h 5 min;
#      board 2 the fixes, two workers (item 3), 2 h 5 min.
set -uo pipefail
S=/home/flo/work/opentoit-sandbox-artifacts/liveness/scripts
cd "$S"
echo "plan: A/B start $(date -Is)"
bash soak.sh b1 esp32-f2-base-soakl b1-f2-base-ab 2400 > ../logs/b1-f2-base-ab.run 2>&1 &
p1=$!
sleep 5
bash soak.sh b2 esp32-f2-fix-soakl b2-f2-fix-ab 2400 > ../logs/b2-f2-fix-ab.run 2>&1 &
p2=$!
wait $p1 $p2
echo "plan: confirmation start $(date -Is)"
bash soak.sh b1 esp32-f2-fix-soakl b1-f2-fix-long 7500 > ../logs/b1-f2-fix-long.run 2>&1 &
p1=$!
sleep 5
bash soak.sh b2 esp32-f2-fix-soakl2 b2-f2-fix-two 7500 > ../logs/b2-f2-fix-two.run 2>&1 &
p2=$!
wait $p1 $p2
echo "plan: done $(date -Is)"
