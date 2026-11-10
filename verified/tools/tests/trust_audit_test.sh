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

# Regression test of the escape-hatch audit (verified/tools/trust_audit.toit).
#
# trust_audit/verified is a fixture root seeded with every escape hatch the
# audit knows, decoys in comments, strings and char literals that must not
# count, report-only items, parser failures inside and outside verus!, and
# an allowlist with listed, unlisted, miscounted, unjustified, duplicate,
# incomplete and stale entries; trust_audit/*.nocheat.log are fixture
# outputs of `verus --no-cheating`. The audit runs on a copy, once checking
# and once with --update-allowlist; its output, THEOREMS.txt and the
# rewritten TRUSTED.toml must equal trust_audit/expected. The expected files
# were produced by the Python audit this tool replaced (verified/tools/
# trust_audit.py, removed), so they also pin the port to the original.
#
# After an intended change of the audit, regenerate the expectations with
# --update and review the diff.
#
# Usage: verified/tools/tests/trust_audit_test.sh [--update]
# TOIT selects the toit executable (default: build/host/sdk/bin/toit).

set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TOIT="${TOIT:-$REPO/build/host/sdk/bin/toit}"
FIXTURE="$HERE/trust_audit"
EXPECTED="$FIXTURE/expected"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/trust-audit-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

"$TOIT" compile --snapshot -o "$WORK/audit.snapshot" "$REPO/verified/tools/trust_audit.toit" || exit 1

failures=0
# check NAME ACTUAL: compares ACTUAL with $EXPECTED/NAME (or updates it).
check() {
  if [ $UPDATE = 1 ]; then
    cp "$2" "$EXPECTED/$1"
  elif ! diff -u "$EXPECTED/$1" "$2"; then
    echo "FAIL: $1 differs from $EXPECTED/$1"
    failures=$((failures + 1))
  fi
}

# Run 1: check the fixture, with the --no-cheating cross-check (including
# a crate the audit does not know).
cp -r "$FIXTURE/verified" "$WORK/run1"
(cd "$WORK" && mv run1 verified && "$TOIT" run audit.snapshot -- --root verified \
    --verus-no-cheating-log "core=$FIXTURE/core.nocheat.log" \
    --verus-no-cheating-log "spec=$FIXTURE/spec.nocheat.log" \
    --verus-no-cheating-log "bogus=$FIXTURE/spec.nocheat.log" > audit.out)
rc=$?
if [ $rc != 1 ]; then
  echo "FAIL: the audit of the fixture exited with $rc, expected 1"
  failures=$((failures + 1))
fi
check audit.out "$WORK/audit.out"
check THEOREMS.txt "$WORK/verified/THEOREMS.txt"
rm -rf "$WORK/verified"

# Run 2: --update-allowlist rewrites TRUSTED.toml, keeping justifications.
cp -r "$FIXTURE/verified" "$WORK/verified"
(cd "$WORK" && "$TOIT" run audit.snapshot -- --root verified --update-allowlist > update.out)
rc=$?
if [ $rc != 1 ]; then
  echo "FAIL: the audit with --update-allowlist exited with $rc, expected 1"
  failures=$((failures + 1))
fi
check update.out "$WORK/update.out"
check TRUSTED.toml "$WORK/verified/TRUSTED.toml"

if [ $UPDATE = 1 ]; then
  echo "Updated $EXPECTED; review the diff."
  exit 0
fi
if [ $failures != 0 ]; then
  echo "trust_audit_test: $failures failure(s)"
  exit 1
fi
echo "trust_audit_test: passed"
