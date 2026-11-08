#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Builds the libFuzzer harnesses with clang, ASan and UBSan in build/fuzz.
# Requires a normal host build first (for the host 'toit' that compiles the
# embedded boot snapshot): make sdk.

set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BUILD_DIR=${BUILD_DIR:-$ROOT/build/fuzz}
HOST_TOIT=${HOST_TOIT:-$ROOT/build/host/sdk/bin/toit}
SANITIZE="-fsanitize=address,undefined -fsanitize=fuzzer-no-link -fno-sanitize-recover=undefined -fno-omit-frame-pointer -g"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
LOCAL_CFLAGS="$SANITIZE" LOCAL_CXXFLAGS="$SANITIZE" LOCAL_LDFLAGS="-fsanitize=address,undefined" \
  CC=clang CXX=clang++ \
  cmake "$ROOT" -G Ninja \
    -DHOST_TOIT="$HOST_TOIT" \
    -DTOIT_FUZZ_BOOT_SNAPSHOT_CC="$ROOT/build/host/generated/toit_run_snapshot.cc" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/toolchains/host.cmake" \
    -DBUILD_TESTING=OFF \
    -DTOIT_BUILD_FUZZERS=ON \
    --no-warn-unused-cli > /dev/null
ninja build_fuzzers
echo "Fuzzers are in $BUILD_DIR/fuzz"
