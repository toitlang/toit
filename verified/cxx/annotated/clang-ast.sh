#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Dumps Clang's JSON AST of the declarations of a C++ file whose qualified
# name contains FILTER, compiled as the host build compiles the VM (the
# flags of src/CMakeLists.txt that change what the code means: the
# language standard and the defines; the include paths of the build).
#
# Usage: clang-ast.sh [--target TRIPLE] [--repo DIR] FILE FILTER OUT
#   FILE is relative to the repository root. Without --target, the host.
# The cxx_render.toit translator calls this; it can also be run by hand.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

TARGET=()
while [ $# -gt 3 ]; do
  case "$1" in
    --target) TARGET=(--target="$2"); shift 2 ;;
    # Another source tree (a mutant: mutant.sh).
    --repo) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    *) echo "clang-ast.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
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
  -DTOIT_MODEL='"render"' -DVM_GIT_INFO='"render"' -DVM_GIT_VERSION='"render"' \
  -Xclang -ast-dump=json -Xclang "-ast-dump-filter=$filter" \
  "$file" > "$out"

# An index of the top-level declarations (Clang prints them one after the
# other, a class with its members): name, first byte, end byte. Their keys
# are indented by two spaces, a child's by more.
LC_ALL=C awk 'BEGIN { pos = 0 }
  /^{$/ { start = pos; name = "" }
  /^  "name": "/ && name == "" { name = $0; sub(/^  "name": "/, "", name); sub(/".*$/, "", name) }
  { pos += length($0) + 1 }
  /^}$/ { print (name == "" ? "-" : name), start, pos }
' "$out" > "$out.index"
