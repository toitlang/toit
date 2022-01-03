#!/bin/bash
# Copyright (C) 2019 Toitware ApS. All rights reserved.

if [ "$1" = "--update" ]; then
  TOIT_UPDATE_GOLD=true
  shift
fi

TOITC="$1"
INPUT="$2"
GOLD="$3"
LIB_PATH="$4"
NORMALIZE_GOLD="$5"
TEST_ROOT="$6"

# Ensure stderr is captured in OUTPUT (2>&1).
OUTPUT=$("$TOITC" --analyze --show-package-warnings -Xlib_path="$LIB_PATH" "$INPUT" 2>&1)

NORMALIZED=$(echo "${OUTPUT}" | "$NORMALIZE_GOLD" "$TEST_ROOT")

if [ "$TOIT_UPDATE_GOLD" == true ]; then
  if [ "$NORMALIZED" == "" ]; then
    # Do nothing. Gold files are supposed to be deleted.
    exit 0
  else
    echo "$NORMALIZED" > "$GOLD"
    echo "Updated $GOLD"
  fi
else
  if [ "$NORMALIZED" == "" ]; then
    if [ -f "$GOLD" ]; then
      echo "Gold file for $INPUT exists, but no output."
      exit 1
    fi
  else
    if [ -f "$GOLD" ]; then
      echo "$NORMALIZED" | diff -u "$GOLD" -
    else
      echo "Unexpected error"
      echo "$NORMALIZED"
      exit 1
    fi
  fi
fi
