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

# The differential test of the proved collector against the C++ prototype
# (tests/difftest.rs): runs sandboxed programs with the copying collector
# and heap dumps (TOIT_SANDBOX_GC=copying, TOIT_GC_DUMP; src/sandbox_gc.cc),
# then compares every dumped collection.
#
# Usage: verified/gc/difftest.sh BUILD-DIR OUT-DIR [PROGRAM [ARGS...]]
#   BUILD-DIR: a host build (build/host, or build/host32-4k for 32-bit words
#   with 4 kB pages). Without PROGRAM: the sandbox ctests of BUILD-DIR
#   (needs its ctest configuration). With PROGRAM: that program, run by
#   BUILD-DIR's toit.run (for example the stage-1 workloads, gcload.toit).
#   The dumps go to OUT-DIR (a new directory per run is best: files of
#   earlier runs are compared too). The word size of the comparison is
#   the build's (i686 for a 32-bit build).
# Env: DUMP_MAX (collections dumped per process, default 4), JOBS (6).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUILD="$(cd "$1" && pwd)"; OUT="$2"; shift 2
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
export TMPDIR="${TMPDIR:-$REPO/build/tmp}"
JOBS="${JOBS:-6}"
RUN="$BUILD/sdk/lib/toit/bin/toit.run"
export TOIT_SANDBOX_GC=copying TOIT_GC_DUMP="$OUT" TOIT_GC_DUMP_MAX="${DUMP_MAX:-4}"
if [ $# -eq 0 ]; then
  ctest --test-dir "$BUILD" -R '^tests/sandbox/' -j"$JOBS" --timeout 300 > "$OUT/ctest.log" 2>&1 \
    || { tail -20 "$OUT/ctest.log"; echo "sandbox ctests failed"; exit 1; }
else
  TOIT_BYTECODE_FORMAT=2 TOIT_V2_UNCHECKED=0 "$RUN" "$@" > "$OUT/run.log" 2>&1 || true
fi
target=()
if file -L "$RUN" | grep -q '32-bit'; then target=(--target i686-unknown-linux-gnu); fi
cd "$HERE"
TOIT_GC_DIFF="$OUT" CARGO_TARGET_DIR="$REPO/build/gc-target" \
  cargo test -q -j"$JOBS" --release "${target[@]}" --test difftest -- --nocapture 2>&1 \
  | grep -E '^differential|^MISMATCH|^test result'
