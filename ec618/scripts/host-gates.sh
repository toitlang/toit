#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Host gates: rebuild the host SDK, verified/check.sh --tests, the sandbox ctests.
set -u
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
L=/home/flo/work/opentoit-sandbox-artifacts/ec618/logs
cd "$WT"
export IGNORE_SUBMODULE=1 IDF_PATH="$WT/third_party/esp-idf" CCACHE_BASEDIR="$WT" CCACHE_NOHASHDIR=1
make sdk > "$L/gate-sdk.log" 2>&1 && echo "sdk: ok" || echo "sdk: FAILED"
verified/check.sh --tests > "$L/gate-check.log" 2>&1 && echo "check.sh --tests: ok" || echo "check.sh --tests: FAILED"
(cd build/host && ctest -j16 -R tests/sandbox/ > "$L/gate-ctest-sandbox.log" 2>&1) && echo "ctest sandbox: ok" || echo "ctest sandbox: FAILED"
tail -3 "$L/gate-ctest-sandbox.log"
