#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-final: the speed sessions: f1 and f2 (suffix fin) at the four code
# pads (pad-sessions.sh, r1), then the unpadded builds twice more (r2 with
# the boards swapped, r3 as r1).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
cd "$A" || exit 1
bash scripts/pad-sessions.sh fin r1
bash scripts/session.sh b2 esp32 r2 f1-fin & bash scripts/session.sh b1 esp32 r2 f2-fin; wait
bash scripts/session.sh b1 esp32 r3 f1-fin & bash scripts/session.sh b2 esp32 r3 f2-fin; wait
echo "speed queue done"
