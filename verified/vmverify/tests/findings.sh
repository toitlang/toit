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

# Regression test for the fuzz findings (verified/core/fuzz/findings): the
# VM's verifier (`toit.run --verify`) must handle every reproducer without
# a panic (PHASE4-REQUESTS.md R6), and reject the ones it must reject:
# infer-panic-* (malformed method tables) and r5-* (task fields).
#
# Usage: findings.sh [TOIT_RUN]

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TOIT_RUN="${1:-$REPO/build/host/sdk/lib/toit/bin/toit.run}"
FINDINGS="$REPO/verified/core/fuzz/findings"

failures=0
count=0
for f in "$FINDINGS"/*.snapshot; do
  name="$(basename "$f" .snapshot)"
  count=$((count + 1))
  out="$("$TOIT_RUN" --verify "$f" 2>&1)"
  rc=$?
  if grep -q "panicked\|verifier failure" <<< "$out"; then
    echo "FAIL $name: the verifier panicked"
    echo "$out" | head -5
    failures=$((failures + 1))
    continue
  fi
  case "$name" in
    infer-panic-*|r5-*)
      if [ "$rc" -ne 1 ] || ! grep -q "rejected" <<< "$out"; then
        echo "FAIL $name: expected a rejection (exit code $rc)"
        echo "$out" | head -5
        failures=$((failures + 1))
        continue
      fi
      ;;
  esac
  echo "ok   $name (exit code $rc)"
done
echo "findings: $count reproducers, $failures failures"
[ "$failures" -eq 0 ]
