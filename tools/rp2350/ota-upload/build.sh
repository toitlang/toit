#!/bin/sh
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

set -eu

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SOURCE_DIR/../../.." && pwd)
BUILD_DIR=${1:-"$REPOSITORY_ROOT/build/rp2350-ota-upload"}

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" --target ota-upload
printf '%s\n' "$BUILD_DIR/ota-upload"
