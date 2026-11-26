#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# floor-confirm: the board plan. Every flash goes through soak.sh -> flash.sh
# -> guard.sh (allow-list and chip check). One board per run, the two
# boards in parallel:
# (The free-heap runs, hwinstall 150 s on f2 and f2hb, ran before.)
#   board 1: (a) f2, one sandboxed
#            worker, 2 h; (c) f2hb (heartbeat), three workers, 45 min.
#   board 2: (b) f2hb, two workers,
#            2 h; (d) f2hb, one worker plus the hog, 45 min.
# The echo server (scripts/echo-server.sh) must be running.
set -uo pipefail
S=/home/flo/work/opentoit-sandbox-artifacts/floor-confirm/scripts
cd "$S"
echo "plan: start $(date -Is)"
(
  bash soak.sh b1 esp32-f2-soakl b1-a-one 7200 > ../logs/b1-a-one.run 2>&1
  echo "plan: b1 a done $(date -Is)"
  bash soak.sh b1 esp32-f2hb-soakl3 b1-c-three 2700 > ../logs/b1-c-three.run 2>&1
  echo "plan: b1 c done $(date -Is)"
) &
p1=$!
sleep 5
(
  bash soak.sh b2 esp32-f2hb-soakl2 b2-b-two 7200 > ../logs/b2-b-two.run 2>&1
  echo "plan: b2 b done $(date -Is)"
  bash soak.sh b2 esp32-f2hb-soakh b2-d-hog 2700 > ../logs/b2-d-hog.run 2>&1
  echo "plan: b2 d done $(date -Is)"
) &
p2=$!
wait $p1 $p2
echo "plan: done $(date -Is)"
