#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# A debug host build (build/dbg) of the worktree: -Xtrace prints every
# format-2 opcode (opcount.sh).
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a063f79f8b4a649b9
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-3
cd "$WT" || exit 1
# shellcheck disable=SC1091
. build/worktree-env.sh
export TMPDIR=$WT/build/tmp
mkdir -p build/dbg
cd build/dbg || exit 1
{
  [ -f build.ninja ] || cmake -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_TOOLCHAIN_FILE="$WT/toolchains/host.cmake" --no-warn-unused-cli "$WT"
  ninja -j10 build_tools
  echo "exit $?"
} > "$A/logs/build-dbg.log" 2>&1
tail -1 "$A/logs/build-dbg.log"
