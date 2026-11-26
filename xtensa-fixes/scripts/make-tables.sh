#!/usr/bin/env bash
# Writes the verifier's FFI input (`.tables`, tables.rs) of a few format-2
# programs with the 32-bit host VM (build/host32), so that a 32-bit
# verifier (i686 host, Xtensa under QEMU) can load them.
# Usage: make-tables.sh <worktree> <out-dir>
set -euo pipefail
WT=$1
OUT=$2
mkdir -p "$OUT"
B=$WT/build/host32/sdk/lib/toit/bin
printf 'main:\n  print "hello"\n' > "$OUT/hello.toit"
PROGRAMS=("$OUT/hello.toit" "$WT/tests/lambda-test.toit" "$WT/tests/exception-test.toit"
          "$WT/tests/class-id-test.toit" "$WT/tests/task-test.toit")
for p in "${PROGRAMS[@]}"; do
  name=$(basename "$p" .toit)
  [ "$p" = "$OUT/$name.toit" ] || cp "$p" "$OUT/$name.toit"
  p=$OUT/$name.toit
  "$B/toit.compile" -Xbytecode_format=2 -w "$OUT/$name.snapshot" "$p"
  "$B/toit.run" --verify --emit-canonical="$OUT/$name.tables" "$OUT/$name.snapshot"
  ls -l "$OUT/$name.tables"
done
