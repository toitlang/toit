#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Rebuilds the worktree's host SDK (make sdk) with the worktree environment
# and the version string fw.sh pins.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a063f79f8b4a649b9
cd "$WT"
export TMPDIR=$WT/build/tmp
# shellcheck disable=SC1091
. build/worktree-env.sh
export TOIT_GIT_VERSION=v2.0.1-pre.999+rpc-task-speed-3
make "${@:-sdk}"
