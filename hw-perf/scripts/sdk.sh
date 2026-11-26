#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Rebuilds the worktree's host SDK (make sdk) with the worktree environment.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a9ac5b95cde68f981
cd "$WT"
# shellcheck disable=SC1091
. build/worktree-env.sh
make sdk
