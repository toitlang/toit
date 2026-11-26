#!/usr/bin/env bash
# Builds the EC618 VM library (the first step of `make ec618-link`: toit_vm
# and mbedtls for thumbv7m with toolchains/ec618.cmake), without the base
# and slot links (those need xmake and the LuatOS SDK build).
# Usage: ec618-vm.sh
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc}
GCC=$HOME/.xmake/packages/g/gnu_rm/2021.10/69b9a9c7bd56401fb164f28701b1431e
export IGNORE_SUBMODULE=1
export IDF_PATH="$WT/third_party/esp-idf"
mkdir -p "$WT/build/ec618"
cd "$WT/build/ec618"
cmake "$WT" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE="$WT/toolchains/ec618.cmake" -DEC618_GCC_PATH="$GCC" --no-warn-unused-cli
ninja toit_vm mbedtls mbedx509 mbedcrypto
ls -l src/libtoit_vm.a
