#!/bin/bash
# Copyright (C) 2019 Toitware ApS. All rights reserved.

if [ "$1" = "--update" ]; then
  TOIT_UPDATE_GOLD=true
  shift
fi

TOITVM="$1"; shift
TEST="$1"; shift
GOLD="$1"; shift
LIB_DIR="$1"; shift
NORMALIZE_GOLD="$1"; shift
TEST_ROOT="$1"; shift
GIT_VERSION="$1"; shift

if grep -q "// TEST_FLAGS:" "$TEST"; then
  TEST_FLAGS=$(grep "// TEST_FLAGS:" "$TEST" | cut -d':' -f2)
fi

# Ensure stderr is captured in OUTPUT (2>&1).
OUTPUT=$("$TOITVM" $TEST_FLAGS -Xenable-asserts -Xlib_path="$LIB_DIR" "$TEST" 2>&1)
EXIT_CODE=$?

set -e

# Negative tests should fail.
if [ "$EXIT_CODE" = "0" ]; then
  echo "Didn't fail with non-zero exit code"
  exit 1
fi

NORMALIZED=$(echo "${OUTPUT}" | "$NORMALIZE_GOLD" "$TEST_ROOT" "$GIT_VERSION")

if [ "$TOIT_UPDATE_GOLD" = true ]; then
  mkdir -p "$(dirname "$GOLD")"
  echo "$NORMALIZED" > "$GOLD"
else
  echo "$NORMALIZED" | diff -u "$GOLD" -
fi
