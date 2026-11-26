#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: reconfigures the worktree's host build with the version
# string fw.sh pins (a snapshot must carry the firmware's SDK version), then
# builds it.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-aa2e69417f86ec26e
cd "$WT"
export TMPDIR=$WT/build/tmp
V=v2.0.1-pre.999+oomconfirm
cmake "-DTOIT_GIT_VERSION=$V" build/host > /dev/null
ninja -C build/host -j8
build/host/sdk/bin/toit version
