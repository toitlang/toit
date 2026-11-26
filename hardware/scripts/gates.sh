#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Host gates of the worktree: build, verified/check.sh --tests, ctest -j16.
# Logs in logs/gate-TAG-*.log.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/hardware
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ad2fa912738994022
TAG=${1:-m1}
cd "$WT" || exit 1
# shellcheck disable=SC1091
. build/worktree-env.sh
make sdk > "$A/logs/gate-$TAG-build.log" 2>&1 || { echo "build failed"; exit 1; }
(cd build/host && ninja build_test_assets) >> "$A/logs/gate-$TAG-build.log" 2>&1
verified/check.sh --tests > "$A/logs/gate-$TAG-check.log" 2>&1
echo "check.sh exit $?"
(cd build/host && ctest -j16 --timeout 600) > "$A/logs/gate-$TAG-ctest.log" 2>&1
echo "ctest exit $?"
tail -15 "$A/logs/gate-$TAG-ctest.log"
