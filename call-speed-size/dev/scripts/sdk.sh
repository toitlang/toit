#!/usr/bin/env bash
# Rebuilds the host SDK of the device/format2 worktree (make sdk with the
# worktree environment of tools/worktree-setup.sh). Usage: sdk.sh [make-args]
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc}
cd "$WT"
export IGNORE_SUBMODULE=1
export IDF_PATH="$WT/third_party/esp-idf"
export CCACHE_BASEDIR="$WT"
export CCACHE_NOHASHDIR=1
make "${@:-sdk}"
