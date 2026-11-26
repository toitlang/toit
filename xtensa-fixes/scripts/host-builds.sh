#!/usr/bin/env bash
# Builds the 64-bit host SDK (make sdk) and the 32-bit host VM
# (build/host32, toolchains/host32.cmake: Rust core for i686) of a
# worktree. The 32-bit toit.run writes the 32-bit `.tables` inputs
# (--emit-canonical=X.tables) that the Xtensa verifier run consumes.
# Usage: host-builds.sh <worktree>
set -euo pipefail
WT=$1
cd "$WT"
export IGNORE_SUBMODULE=1
export IDF_PATH="$WT/third_party/esp-idf"
export CCACHE_BASEDIR="$WT"
export CCACHE_NOHASHDIR=1
start=$(date +%s)
make sdk
mid=$(date +%s)
cmake -S . -B build/host32 -G Ninja -DHOST_TOIT="$WT/build/host/sdk/bin/toit" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$WT/toolchains/host32.cmake" -Wno-dev > /dev/null
ninja -C build/host32 build_tools build_version_file
end=$(date +%s)
echo "host sdk $((mid - start)) s, host32 $((end - mid)) s"
