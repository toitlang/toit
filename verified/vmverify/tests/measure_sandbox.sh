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

# Runs the sandbox ctests with TOIT_VERIFY_TIME=1 and summarizes every
# verification of an untrusted launch: count, bytecodes, peak memory (the
# counting allocator of vmverify) and total time (min, median, max).
#
# Usage: measure_sandbox.sh [BUILD_DIR]

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${1:-$HERE/../../../build/host}"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
TOIT_VERIFY_TIME=1 ctest --test-dir "$BUILD" -R '^tests/sandbox/' -j "${JOBS:-8}" -V > "$LOG" 2>&1
grep -o 'verifier: [a-z]*, [0-9]* methods, [0-9]* bytecodes, [0-9]* objects; convert [0-9.]* ms, heap [0-9.]* ms, infer [0-9.]* ms, check [0-9.]* ms; peak [0-9]* KB' "$LOG" \
  | python3 -c '
import re, statistics, sys
rows = []
for line in sys.stdin:
    m = re.search(r"verifier: (\w+), (\d+) methods, (\d+) bytecodes, (\d+) objects; convert ([\d.]+) ms, heap ([\d.]+) ms, infer ([\d.]+) ms, check ([\d.]+) ms; peak (\d+) KB", line)
    if m:
        v = m.groups()
        total = sum(float(x) for x in v[4:8])
        rows.append((v[0], int(v[1]), int(v[2]), int(v[3]), float(v[6]), float(v[7]), total, int(v[8])))
if not rows:
    print("no verifications found"); sys.exit(1)
def span(xs, fmt):
    return ("%s-%s (median %s)" % (fmt % min(xs), fmt % max(xs), fmt % statistics.median(xs)))
print("verifications: %d (%d accepted)" % (len(rows), sum(1 for r in rows if r[0] == "accepted")))
print("methods: " + span([r[1] for r in rows], "%d"))
print("bytecodes: " + span([r[2] for r in rows], "%d"))
print("objects: " + span([r[3] for r in rows], "%d"))
print("infer ms: " + span([r[4] for r in rows], "%.1f"))
print("check ms: " + span([r[5] for r in rows], "%.1f"))
print("total ms: " + span([r[6] for r in rows], "%.1f"))
print("peak KB: " + span([r[7] for r in rows], "%d"))
'
grep -E '^[0-9]+% tests passed|tests failed' "$LOG" | tail -2
