#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Prepares the device/measure-3 worktree for host builds (tools/worktree-setup.sh)
# with the pinned version string.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a8cbed86ae1ed9653
cd "$WT"
export TMPDIR=$WT/build/tmp
mkdir -p "$TMPDIR"
export TOIT_GIT_VERSION=v2.0.1-pre.999+measure-3
bash tools/worktree-setup.sh "$@"
