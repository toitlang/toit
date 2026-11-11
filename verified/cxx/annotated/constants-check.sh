#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Checks the model's constant table against the C++ headers: compiles every
# generated *.gen.constants.cc (one static_assert per constant use of a
# rendering, written by cxx_render.toit) for the host (64-bit) and for
# i686 (32-bit). Private members are reached with -fno-access-control.
#
# Usage: constants-check.sh [FILE...]   (default: all of them)

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$ANNOTATED_DIR"
[ $# -eq 0 ] && set -- $(ls */*.gen.constants.cc)
CLANG="${CLANGXX:-clang++}"
status=0
for f in "$@"; do
  for target in x86_64-linux-gnu i686-linux-gnu; do
    if "$CLANG" --target="$target" -fsyntax-only -fno-access-control -std=gnu++11 \
        -DTOIT_DEPLOY -DTOIT_VERIFIED_CORE \
        -I"$REPO_ROOT/src" -I"$REPO_ROOT/include" -I"$REPO_ROOT/third_party/dragonbox/include" \
        -I"$REPO_ROOT/third_party/esp-idf/components/mbedtls/mbedtls/include" \
        "-DMBEDTLS_CONFIG_FILE=\"$REPO_ROOT/mbedtls/include/toit_config.h\"" \
        "$f" > "$ACXX_HOME/logs/constants-$(basename "$f")-$target.log" 2>&1; then
      printf 'ok    constants %-40s %s (%d checks)\n' "$f" "$target" "$(grep -c static_assert "$f")"
    else
      printf 'FAIL  constants %-40s %s:\n' "$f" "$target"
      grep -E "error|static assertion" "$ACXX_HOME/logs/constants-$(basename "$f")-$target.log" | head -10
      status=1
    fi
  done
done
exit $status
