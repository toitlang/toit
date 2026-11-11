#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Dumps Clang's JSON AST of the declarations of a C++ file whose qualified
# name contains FILTER, compiled as the host build compiles the VM (the
# flags of src/CMakeLists.txt that change what the code means: the
# language standard and the defines; the include paths of the build).
#
# Usage: clang-ast.sh [--target TRIPLE] FILE FILTER OUT
#   FILE is relative to the repository root. Without --target, the host.
# The cxx_render.toit translator calls this; it can also be run by hand.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

TARGET=()
if [ "${1:-}" = --target ]; then
  TARGET=(--target="$2")
  shift 2
fi
file="$1"
filter="$2"
out="$3"
CLANG="${CLANGXX:-clang++}"

cd "$REPO_ROOT"
"$CLANG" "${TARGET[@]}" -fsyntax-only -std=gnu++11 \
  -DTOIT_DEPLOY -DTOIT_VERIFIED_CORE \
  -Iinclude -Ithird_party/dragonbox/include \
  -Ithird_party/esp-idf/components/mbedtls/mbedtls/include \
  "-DMBEDTLS_CONFIG_FILE=\"$REPO_ROOT/mbedtls/include/toit_config.h\"" \
  -Xclang -ast-dump=json -Xclang "-ast-dump-filter=$filter" \
  "$file" > "$out"
