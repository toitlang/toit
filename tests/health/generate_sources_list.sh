#!/bin/bash
# Copyright (C) 2020 Toitware ApS. All rights reserved.

set -e

BASE="$1"
OUT="$2"

echo "set(HEALTH_SOURCES" > "$OUT"
# readlink -f doesn't exist on macos.
# Roll out our own version:
while [ -L "$BASE" ]; do
  BASE=$(readlink "$BASE")
  cd "$BASE"
  BASE=$(pwd -P)
done
echo $BASE
# Prune .git and tests/negative.
# `-o`: otherwise.
find "$BASE" \
  -path "$BASE/.git" -prune -o             \
  -path "$BASE/tests/negative" -prune -o   \
  -path "$BASE/tools/tpkg/tests" -prune -o \
  -path "$BASE/openme.skeleton" -prune -o \
  -type f        \
  -name '*.toit' \
  -exec echo '"'{}'"' >> "$OUT" \;
echo ")" >> "$OUT"
