#!/usr/bin/env bash
# Compiles suite tests in format 2 and turns them into 32-bit container
# images with their shipped certificate block (what a device installs as an
# untrusted container). Also records the host reference: each test run
# untrusted on the 64-bit and the 32-bit host VM (exit code and output).
# Usage: make-images.sh <worktree> <out-dir> <test.toit>...
set -uo pipefail
WT=$1
OUT=$2
shift 2
mkdir -p "$OUT"
TOIT=$WT/build/host/sdk/bin/toit
cp "$WT/tests/confuse.toit" "$OUT/" 2>/dev/null
for t in "$@"; do
  name=$(basename "$t" .toit)
  cp "$WT/$t" "$OUT/$name.toit"
  "$WT/build/host/sdk/lib/toit/bin/toit.compile" -Xbytecode_format=2 -w "$OUT/$name.snapshot" "$OUT/$name.toit" \
    || { echo "$name: compile failed"; continue; }
  "$TOIT" tool snapshot-to-image -m32 --format binary -o "$OUT/$name.image" "$OUT/$name.snapshot" \
    || { echo "$name: image failed"; continue; }
  (cd "$WT" && "$WT/build/host/sdk/lib/toit/bin/toit.run" --untrusted "$OUT/$name.snapshot" > "$OUT/$name.host64.out" 2>&1; echo "exit $?" >> "$OUT/$name.host64.out")
  (cd "$WT" && "$WT/build/host32/sdk/lib/toit/bin/toit.run" --untrusted "$OUT/$name.snapshot" > "$OUT/$name.host32.out" 2>&1; echo "exit $?" >> "$OUT/$name.host32.out")
  echo "$name image $(stat -c %s "$OUT/$name.image") host64 $(tail -1 "$OUT/$name.host64.out") host32 $(tail -1 "$OUT/$name.host32.out")"
done
