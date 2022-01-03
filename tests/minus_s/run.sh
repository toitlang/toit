#!/bin/bash
# Copyright (C) 2021 Toitware ApS. All rights reserved.

if [ "$1" = "--update" ]; then
  TOIT_UPDATE_GOLD=true
  shift
fi

TOITVM="$1"; shift
TEST="$1"; shift
GOLD="$1"; shift

# Ensure stderr is captured in OUTPUT (2>&1).
OUTPUT=$("$TOITVM" -Xenable-asserts -s "$(cat $TEST)" 2>&1)
EXIT_CODE=$?

set -e

FULL_OUTPUT="Exit Code: $EXIT_CODE
$OUTPUT"

if [ "$TOIT_UPDATE_GOLD" = true ]; then
  mkdir -p "$(dirname "$GOLD")"
  echo "$FULL_OUTPUT" > "$GOLD"
else
  echo "$FULL_OUTPUT" | diff -u "$GOLD" -
fi
