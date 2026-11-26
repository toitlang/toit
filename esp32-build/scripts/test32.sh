#!/usr/bin/env bash
# Configures (first time) and builds the 32-bit host VM of this worktree
# (toolchains/host32.cmake) and runs the sandbox ctests and the layout check
# on it. Extra arguments go to ctest.
set -e
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
cd "$WT"
export IGNORE_SUBMODULE=1 IDF_PATH=$WT/third_party/esp-idf CCACHE_BASEDIR=$WT CCACHE_NOHASHDIR=1
if [ ! -f build/host32/build.ninja ]; then
  cmake -S . -B build/host32 -G Ninja -DHOST_TOIT="$WT/build/host/sdk/bin/toit" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$WT/toolchains/host32.cmake" -Wno-dev > /dev/null
fi
ninja -C build/host32 build_tools build_version_file > build/host32-build.log 2>&1 || { tail -20 build/host32-build.log; exit 1; }
cmake build/host32 > /dev/null 2>&1
ctest --test-dir build/host32 -R "^tests/sandbox/|verified_core_layout" -j16 --output-on-failure "$@"
