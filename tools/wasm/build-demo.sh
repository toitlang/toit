#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# Assembles the WebAssembly demo (examples/wasm) into a directory that can be
# served with any static web server:
#
#   tools/wasm/build-demo.sh
#   python3 -m http.server -d build/wasm/demo

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST_TOIT="${HOST_TOIT:-$ROOT/build/host/sdk/bin/toit}"
WASM_DIR="${WASM_DIR:-$ROOT/build/wasm/sdk/wasm}"
OUT="${1:-$ROOT/build/wasm/demo}"

mkdir -p "$OUT/programs"
cp "$WASM_DIR/toit.mjs" "$WASM_DIR/toit-vm.mjs" "$WASM_DIR/toit-vm.wasm" "$OUT/"
cp "$ROOT"/examples/wasm/web/* "$OUT/"
for source in "$ROOT"/examples/wasm/*.toit; do
  name="$(basename "$source" .toit)"
  cp "$source" "$OUT/programs/"
  "$HOST_TOIT" compile --snapshot -O2 -o "$OUT/programs/$name.snapshot" "$source"
done
echo "Demo written to $OUT"
