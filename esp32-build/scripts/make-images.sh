#!/usr/bin/env bash
# Compiles suite tests in format 2 (toit.compile ships the certificate) and
# turns them into 32-bit container images with their certificate block
# (what a device installs as an untrusted container). Records the 64-bit
# host's untrusted run as the reference.
# Usage: make-images.sh OUT-DIR TEST.toit...   (paths relative to the worktree)
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
OUT=$1
shift
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
  echo "$name image $(stat -c %s "$OUT/$name.image") host64 $(tail -1 "$OUT/$name.host64.out")"
done
