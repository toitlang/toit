#!/usr/bin/env bash
# Builds the host tools of the worktree (ninja build_tools in build/host,
# or the given build dir) and optionally runs ctest with a regex.
# Usage: hostbuild.sh [BUILD-DIR] [CTEST-REGEX]
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
B=${1:-build/host}
export IGNORE_SUBMODULE=1 IDF_PATH=$WT/third_party/esp-idf CCACHE_BASEDIR=$WT CCACHE_NOHASHDIR=1
cd "$WT"
ninja -C "$B" build_tools > /home/flo/work/opentoit-sandbox-artifacts/esp32-build/hostbuild.log 2>&1 \
  || { grep -E 'error|FAILED' /home/flo/work/opentoit-sandbox-artifacts/esp32-build/hostbuild.log | head -30; exit 1; }
grep -E 'warning' /home/flo/work/opentoit-sandbox-artifacts/esp32-build/hostbuild.log | head -10
if [ -n "${2:-}" ]; then
  (cd "$B" && ctest -R "$2" --output-on-failure 2>&1 | tail -40)
fi
