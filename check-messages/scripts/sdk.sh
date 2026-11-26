#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Rebuilds the worktree's host SDK (make sdk) with the pinned version string.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a761e44286b8f7807
cd "$WT"
export TMPDIR=$WT/build/tmp
# shellcheck disable=SC1091
. build/worktree-env.sh
export TOIT_GIT_VERSION=v2.0.1-pre.999+check-messages
make "${@:-sdk}"
