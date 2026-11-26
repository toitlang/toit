#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Prepares the device/esp32-layout worktree for host builds (tools/worktree-setup.sh)
# with the pinned version string.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f
cd "$WT"
export TMPDIR=$WT/build/tmp
mkdir -p "$TMPDIR"
export TOIT_GIT_VERSION=v2.0.1-pre.999+memory-pressure
bash tools/worktree-setup.sh "$@"
