#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Traces calls FROM..TO of the primitive differential for SEED in f1 and f2 on
# the EC618 harness and prints the first differing calls.
# Usage: prim-trace.sh SEED ITERATIONS FROM TO
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
TOIT=$WT/build/host/sdk/bin/toit
SEED=$1; N=$2; FROM=$3; TO=$4
OUT=$A/qemu/prim-diff
P=$A/qemu/progs/prim-trace-$SEED.toit
printf 'import .primitive-diff as diff\nmain:\n  diff.main ["%s", "%s", "%s", "%s"]\n' "$SEED" "$N" "$FROM" "$TO" > "$P"
for f in 1 2; do
  if [ $f = 1 ]; then B=build/ec618; else B=build/ec618-f2; fi
  TOIT_BYTECODE_FORMAT=$f "$TOIT" compile --snapshot -o "$OUT/t$SEED-f$f.snapshot" "$P"
  cp "$WT/$B/firmware.envelope" "$OUT/t$SEED-f$f.envelope"
  "$TOIT" tool firmware -e "$OUT/t$SEED-f$f.envelope" container install diff "$OUT/t$SEED-f$f.snapshot"
  TIMEOUT=7200 bash "$A/scripts/qrun.sh" "$OUT/trace$SEED-f$f.txt" "$B" "$OUT/t$SEED-f$f.envelope" > /dev/null
  grep -a -E '^[0-9]+: ' "$OUT/trace$SEED-f$f.txt" > "$OUT/trace$SEED-f$f.lines" || true
done
wc -l "$OUT/trace$SEED-f1.lines" "$OUT/trace$SEED-f2.lines"
diff -a "$OUT/trace$SEED-f1.lines" "$OUT/trace$SEED-f2.lines" | head -8 | cut -c1-400 || true
