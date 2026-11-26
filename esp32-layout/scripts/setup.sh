#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Prepares the device/esp32-layout worktree for host builds (tools/worktree-setup.sh)
# with the pinned version string.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a075db46027697e45
cd "$WT"
export TMPDIR=$WT/build/tmp
mkdir -p "$TMPDIR"
export TOIT_GIT_VERSION=v2.0.1-pre.999+esp32-layout
bash tools/worktree-setup.sh "$@"
