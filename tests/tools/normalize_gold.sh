#!/bin/bash
# Copyright (C) 2019 Toitware ApS. All rights reserved.

PREFIX_TO_REMOVE="$1"
GIT_VERSION="$2"

set -e

INPUT=$(cat)
REPLACED="${INPUT//$PREFIX_TO_REMOVE/<...>}"

if [ "$GIT_VERSION" ]; then
  REPLACED="${REPLACED//$GIT_VERSION/<GIT_VERSION>}"
fi
echo "$REPLACED"
