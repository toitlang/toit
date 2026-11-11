# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# Source this: tool paths and the VM's compile flags for the harnesses of
# verified/cxx (installed by verified/cxx/install-tools.sh).

CXXV_HOME=${CXXV_HOME:-/home/flo/work/opentoit-sandbox-artifacts/cxx-verification}
CXXV_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ESBMC=$CXXV_HOME/tools/esbmc/release/bin/esbmc
CBMC_BIN=$CXXV_HOME/tools/cbmc/usr/bin
# The VM sources the harnesses include (`#include "utils.cc"`): src/, or a
# patched copy with a known bug put back (verified/cxx/run.sh --mutants).
CXXV_SRC=${CXXV_SRC:-$CXXV_REPO/src}
# The include paths and defines of src/primitive_core.cc in
# build/host/compile_commands.json (host build, release flags).
CXXV_FLAGS=(
  -I"$CXXV_REPO/verified/cxx/include"
  -I"$CXXV_REPO/include"
  -I"$CXXV_SRC"
  -I"$CXXV_REPO/third_party/esp-idf/components/mbedtls/mbedtls/include"
  -I"$CXXV_REPO/third_party/dragonbox/include"
  -DMBEDTLS_CONFIG_FILE="\"$CXXV_REPO/mbedtls/include/toit_config.h\""
  -DTOIT_DEPLOY
  -DTOIT_MODEL="\"\""
  -DVM_GIT_INFO="\"\""
  -DVM_GIT_VERSION="\"cxx-verification\""
)
export CXXV_HOME CXXV_REPO ESBMC CBMC_BIN
