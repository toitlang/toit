#!/usr/bin/env bash
# Configures and builds the 32-bit host VM of the device/certificate-and-size
# worktree (as phase5's build/mk32.sh). Usage: mk32.sh [DIR] [BUILD_TYPE]
set -e
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a9365a74954333c15
cd "$WT"
DIR="${1:-build/host32}"; TYPE="${2:-Release}"
cmake -S . -B "$DIR" -G Ninja -DHOST_TOIT="$WT/build/host/sdk/bin/toit" -DCMAKE_BUILD_TYPE="$TYPE" \
  -DCMAKE_TOOLCHAIN_FILE="$WT/toolchains/host32.cmake" -Wno-dev > /dev/null
ninja -C "$DIR" build_tools build_version_file
