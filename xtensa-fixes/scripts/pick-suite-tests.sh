#!/usr/bin/env bash
# Lists suite tests that run untrusted in format 2 (suite-status "2 pass")
# and import nothing but `expect` and `.confuse` (so they can be embedded in
# a device image without packages), with their source size.
# Usage: pick-suite-tests.sh <worktree>
set -euo pipefail
WT=$1
grep '^2 pass ' "$WT/verified/spec/tests/suite-status.txt" | awk '{print $3}' | while read -r t; do
  f=$WT/$t
  [ -f "$f" ] || continue
  bad=$(grep -E '^import ' "$f" | grep -v -E '^import (expect( show .*)?|\.confuse( show .*)?)\s*$' || true)
  [ -z "$bad" ] || continue
  grep -q 'process\.args\|args\b' "$f" && continue
  echo "$(wc -c < "$f") $t"
done | sort -n
