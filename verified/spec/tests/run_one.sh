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

# Compiles one Toit file and runs it on the C++ VM and on the reference
# interpreter. Extra arguments are passed to toit-spec-run.
#
# Usage: tests/run_one.sh file.toit [toit-spec-run flags...]

set -eu
CRATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$CRATE/../.." && pwd)"
TOIT="${TOIT:-$REPO/build/host/sdk/bin/toit}"
OUT="${OUT:-$CRATE/target/spec-tests}"
mkdir -p "$OUT"
src="$1"
shift
name="$(basename "$src" .toit)"
DUMPER="$OUT/spec_dump.snapshot"
[ -f "$DUMPER" ] || "$TOIT" compile --snapshot -o "$DUMPER" "$REPO/tools/spec_dump.toit"
(cd "$CRATE" && cargo build --release --quiet)
"$TOIT" compile --snapshot -o "$OUT/$name.snapshot" "$src"
"$TOIT" run "$DUMPER" -- "$OUT/$name.snapshot" "$OUT/$name.dump"
echo "=== C++ VM"
"$TOIT" run "$OUT/$name.snapshot" || echo "exit $?"
echo "=== spec"
"$CRATE/target/release/toit-spec-run" "$@" "$OUT/$name.dump" || echo "exit $?"
