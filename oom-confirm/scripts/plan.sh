#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# oom-confirm: the board plan. Every flash goes through soak.sh -> flash.sh
# -> guard.sh (allow-list and chip check). One board per run, the two
# boards in parallel:
#   first a free-heap run (hwinstall: boot, WiFi up), 150 s each: board 1
#   f2, board 2 f1.
#   board 1: (a) f2, one sandboxed worker, 3 h 15 min; then (d) over
#            capacity, f2: three workers 25 min, one worker plus a hog
#            (allocates until refused) 25 min.
#   board 2: (b) f2, two sandboxed workers, 2 h 10 min; then (c) f1, one
#            trusted worker, 2 h 5 min.
# The echo server (scripts/echo-server.sh) must be running.
set -uo pipefail
S=/home/flo/work/opentoit-sandbox-artifacts/oom-confirm/scripts
cd "$S"
echo "plan: start $(date -Is)"
(
  bash soak.sh b1 esp32-f2-install b1-f2-mem 150 > ../logs/b1-f2-mem.run 2>&1
  bash soak.sh b1 esp32-f2-soakl b1-f2-one 11700 > ../logs/b1-f2-one.run 2>&1
  echo "plan: b1 a done $(date -Is)"
  bash soak.sh b1 esp32-f2-soakl3 b1-f2-three 1500 > ../logs/b1-f2-three.run 2>&1
  echo "plan: b1 d1 done $(date -Is)"
  bash soak.sh b1 esp32-f2-soakh b1-f2-hog 1500 > ../logs/b1-f2-hog.run 2>&1
  echo "plan: b1 d2 done $(date -Is)"
) &
p1=$!
sleep 5
(
  bash soak.sh b2 esp32-f1-install b2-f1-mem 150 > ../logs/b2-f1-mem.run 2>&1
  bash soak.sh b2 esp32-f2-soakl2 b2-f2-two 7800 > ../logs/b2-f2-two.run 2>&1
  echo "plan: b2 b done $(date -Is)"
  bash soak.sh b2 esp32-f1-soakl b2-f1-one 7500 > ../logs/b2-f1-one.run 2>&1
  echo "plan: b2 c done $(date -Is)"
) &
p2=$!
wait $p1 $p2
echo "plan: done $(date -Is)"
