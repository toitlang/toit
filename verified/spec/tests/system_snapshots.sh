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

# Compiles the three system snapshots embedded in the host VM (toit,
# toit_run, run_image; see src/CMakeLists.txt) in format 2, dumps them and
# runs the structural verifier on each.
#
# Usage: tests/system_snapshots.sh [out-dir]

set -eu
CRATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$CRATE/../.." && pwd)"
TOIT="${TOIT:-$REPO/build/host/sdk/bin/toit}"
TOIT_COMPILE="$(dirname "$(dirname "$TOIT")")/lib/toit/bin/toit.compile"
OUT="${1:-$CRATE/target/system}"
mkdir -p "$OUT"
(cd "$CRATE" && cargo build --release --quiet --bin toit_spec_verify)
DUMPER="$OUT/spec_dump.snapshot"
[ -f "$DUMPER" ] || "$TOIT" compile --snapshot -o "$DUMPER" "$REPO/tools/spec_dump.toit"
for src in tools/toit.toit system/extensions/host/toit.run.toit system/extensions/host/run-image.toit; do
  name="$(basename "$src" .toit)"
  (cd "$REPO" && "$TOIT_COMPILE" -Xbytecode_format=2 -w "$OUT/$name.snapshot" "$src")
  "$TOIT" run "$DUMPER" -- "$OUT/$name.snapshot" "$OUT/$name.dump"
  echo "=== $name"
  "$CRATE/target/release/toit_spec_verify" --trusted --time "$OUT/$name.dump"
  # The certificate toit.compile shipped, checked by the VM alone (no
  # inference), as a device would.
  "$(dirname "$TOIT_COMPILE")/toit.run" --verify --trusted --require-certificate -q "$OUT/$name.snapshot"
done
