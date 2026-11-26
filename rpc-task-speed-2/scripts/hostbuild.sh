#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Rebuilds the worktree's host VM and tools (build/host, ninja build_tools)
# with the pinned version of sdk.sh. Log: build/tmp/host-build.log.
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a317ce7f79e57a075
cd "$WT" || exit 1
export TMPDIR=$WT/build/tmp
# shellcheck disable=SC1091
. build/worktree-env.sh
export TOIT_GIT_VERSION=v2.0.1-pre.999+rpc-task-speed-2
export CARGO_BUILD_JOBS=8
ninja -C build/host -j8 "${@:-build_tools}" > "$TMPDIR/host-build.log" 2>&1
rc=$?
tail -2 "$TMPDIR/host-build.log"
exit $rc
