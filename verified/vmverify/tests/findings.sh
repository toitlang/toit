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
# infer-panic-* (malformed method tables), r5-* and task-stack-field-store
# (task fields), with the verifier's own rejection ("untrusted program
# rejected: method ..."). Every reproducer must reach the verifier: an image
# the VM refuses before verifying it (another format version, a method table
# the loader rejects) fails the check, so that a format change cannot turn
# the reproducers into images that pass without testing anything (they did
# until 2026-11-26: the TBC2 images were rejected for "no method table";
# verified/core/fuzz/findings/regenerate.sh rebuilds them).
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
  if grep -q "is not supported by this VM\|format-2 program rejected:\|INVALID_SNAPSHOT\|Not a valid snapshot" <<< "$out"; then
    echo "FAIL $name: refused before the verifier ran (regenerate.sh rebuilds the reproducers)"
    echo "$out" | head -5
    failures=$((failures + 1))
    continue
  fi
  if ! grep -q "^VERIFIED \|^REJECTED " <<< "$out"; then
    echo "FAIL $name: no verifier verdict"
    echo "$out" | head -5
    failures=$((failures + 1))
    continue
  fi
  case "$name" in
    infer-panic-*|r5-*|task-stack-field-store)
      if [ "$rc" -ne 1 ] || ! grep -q "untrusted program rejected: method " <<< "$out"; then
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
