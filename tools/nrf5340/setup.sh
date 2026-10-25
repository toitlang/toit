#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
deps="$root/.cache/nrf5340"
mkdir -p "$deps"
fetch() {
  local name=$1 url=$2 revision=$3
  local destination="$deps/$name"
  if [[ ! -d "$destination" ]]; then
    git init -q "$destination"
    git -C "$destination" remote add origin "$url"
    git -C "$destination" fetch --depth 1 origin "$revision"
    git -C "$destination" checkout --detach FETCH_HEAD
  fi
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]] || {
    echo "Unexpected revision in $destination (expected $revision)" >&2
    exit 1
  }
  [[ -z "$(git -C "$destination" status --porcelain --untracked-files=no)" ]] || {
    echo "Modified dependency in $destination" >&2
    exit 1
  }
}
if [[ "${1:-}" == "--openocd" ]]; then
  fetch openocd https://github.com/openocd-org/openocd.git cb0c224e936091156ecf3025ba05657408ed64c8
  (
    cd "$deps/openocd"
    ./bootstrap
    ./configure --enable-ftdi --disable-werror --disable-doxygen-html --disable-doxygen-pdf
    make -j"${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
  )
fi
