#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Prepares the device/check-messages worktree for host builds
# (tools/worktree-setup.sh) with the pinned version string.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a761e44286b8f7807
cd "$WT"
export TMPDIR=$WT/build/tmp
mkdir -p "$TMPDIR"
export TOIT_GIT_VERSION=v2.0.1-pre.999+check-messages
bash tools/worktree-setup.sh "$@"
