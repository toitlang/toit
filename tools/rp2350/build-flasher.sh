#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

# Build the same portable tools bundled by the ordinary SDK build.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
platform=$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)
build_dir="${RP2350_BUILD_ROOT:-$repo_root/build/rp2350-host-tools}"
output="${RP2350_FLASHER_OUTPUT:-$repo_root/build/rp2350-flasher/$platform}"
cmake -S "$script_dir/host-tools" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$output" "$@"
cmake --build "$build_dir" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
cmake --install "$build_dir"
(cd "$(dirname -- "$output")" && cmake -E tar czf \
  "$(basename -- "$output").tar.gz" --format=gnutar "$(basename -- "$output")")
printf 'RP2350 tools: %s\n' "$output"
