#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The second builds verified/check.sh --tests needs for all red-team
# batteries: build/asan (ASan+UBSan, build_tools) and build/host32.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/measure-3
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a8cbed86ae1ed9653
cd "$WT" || exit 1
# shellcheck disable=SC1091
. build/worktree-env.sh
cmake -S . -B build/asan -G Ninja -DCMAKE_BUILD_TYPE=asan -DCMAKE_TOOLCHAIN_FILE="$PWD/toolchains/host.cmake" \
  "-DCMAKE_CXX_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
  "-DCMAKE_C_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
  "-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined" > "$A/logs/asan-build.log" 2>&1 || { echo "asan cmake failed"; exit 1; }
ASAN_OPTIONS=detect_leaks=0 ninja -C build/asan build_tools >> "$A/logs/asan-build.log" 2>&1 || { echo "asan build failed"; exit 1; }
echo "asan ok"
make TARGET=host32 sdk > "$A/logs/host32-build.log" 2>&1 || { echo "host32 build failed"; exit 1; }
echo "host32 ok"
