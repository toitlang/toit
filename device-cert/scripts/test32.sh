#!/usr/bin/env bash
# Rebuilds build/host32 and runs the sandbox ctests on it. Extra arguments go
# to ctest.
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a9365a74954333c15
cd "$WT"
ninja -C build/host32 build_tools build_version_file > build/host32-build.log 2>&1 || { tail -20 build/host32-build.log; exit 1; }
cmake build/host32 > /dev/null 2>&1
ctest --test-dir build/host32 -R "^tests/sandbox/|verified_core_layout" -j16 --output-on-failure "$@"
