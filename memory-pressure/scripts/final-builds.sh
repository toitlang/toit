#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure follow-up: the final builds, one after the other (fw.sh
# shares build/fwsrc: never run two builds at once).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A"
export TMPDIR=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f/build/tmp
REV=$1
SRCREV=$REV SUFFIX=fix bash scripts/fw-all.sh esp32 fix f2
bash scripts/mkenv.sh esp32 f2-fix soakd > logs/mkenv-f2-fix-soakd.txt 2>&1 || echo "fail env soakd"
SRCREV=$REV SUFFIX=fix bash scripts/fw-all.sh esp32 fix f2time
bash scripts/mkenv.sh esp32 f2time-fix install > /dev/null 2>&1 || echo "fail env f2time-fix"
bash scripts/patch-builds.sh "3328 8192" patches/hot-verifier-order-padfirst.patch h1f=b332d8432
bash scripts/patch-builds.sh "3328 8192" patches/hot-pad-first.patch b0f=67e28c2d
