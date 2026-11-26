#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The primitive differential (tests/fuzz/primitive-diff.toit) on the EC618
# harness: format 1 on the C++ interpreter (GCC's C++ primitives) against
# format 2 on the core (the Rust ports, thumbv7m), per seed.
# Usage: prim-diff.sh ITERATIONS SEED...
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
TOIT=$WT/build/host/sdk/bin/toit
N=$1
shift
OUT=$A/qemu/pdiff-fine
mkdir -p "$OUT"
for seed in "$@"; do
  printf 'import .pdiff-fine as diff\nmain:\n  diff.main ["%s", "%s"]\n' "$seed" "$N" > "$A/qemu/progs/pdiff-fine-run-$seed.toit"
  for f in ${FORMATS:-1 2}; do
    if [ $f = 1 ]; then B=build/ec618; else B=build/ec618-f2; fi
    TOIT_BYTECODE_FORMAT=$f "$TOIT" compile --snapshot -o "$OUT/s$seed-f$f.snapshot" "$A/qemu/progs/pdiff-fine-run-$seed.toit"
    cp "$WT/$B/firmware.envelope" "$OUT/s$seed-f$f.envelope"
    "$TOIT" tool firmware -e "$OUT/s$seed-f$f.envelope" container install diff "$OUT/s$seed-f$f.snapshot"
    TIMEOUT=7200 bash "$A/scripts/qrun.sh" "$OUT/seed$seed-f$f.txt" "$B" "$OUT/s$seed-f$f.envelope" > /dev/null
    grep -E '^(checksum|done)' "$OUT/seed$seed-f$f.txt" > "$OUT/seed$seed-f$f.sums" || true
  done
  if [ -s "$OUT/seed$seed-f1.sums" ] && cmp -s "$OUT/seed$seed-f1.sums" "$OUT/seed$seed-f2.sums"; then
    echo "seed $seed: identical ($(tail -1 "$OUT/seed$seed-f2.sums"))"
  else
    echo "seed $seed: DIFFERENT or failed"
    diff "$OUT/seed$seed-f1.sums" "$OUT/seed$seed-f2.sums" | head -4 || true
  fi
done
