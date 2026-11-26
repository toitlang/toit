#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# oom-confirm: added after the first two-worker run (b2-f2-two) lost its
# controller at 46 min: board 1, once plan.sh is done with it, (b') a
# second two-worker run of 1 h 40 min; then two free-heap runs (hwinstall,
# 150 s each) to check the lower WiFi-up figure: the liveness round's
# firmware (esp32-f2-fix of 101a721f/2183fccac, flashed with that round's
# SDK) and this firmware again.
set -uo pipefail
S=/home/flo/work/opentoit-sandbox-artifacts/oom-confirm/scripts
cd "$S"
until grep -q "plan: b1 d2 done" ../logs/plan.log; do sleep 20; done
echo "plan2: start $(date -Is)"
bash soak.sh b1 esp32-f2-soakl2 b1-f2-two 6000 > ../logs/b1-f2-two.run 2>&1
echo "plan2: b' done $(date -Is)"
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a0319253ba15c69bc bash soak.sh b1 esp32-livefix-install b1-livefix-mem 150 > ../logs/b1-livefix-mem.run 2>&1
bash soak.sh b1 esp32-f2-install b1-f2-mem2 150 > ../logs/b1-f2-mem2.run 2>&1
echo "plan2: done $(date -Is)"
