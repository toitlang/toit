#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Counts the guest instructions (QEMU's libinsn plugin, whole run) of each
# benchmark program on a harness build, minus those of the empty program.
# Usage: insn-bench.sh CONFIG-NAME BUILD-DIR FORMAT   (BUILD-DIR relative to the worktree)
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
NAME=$1
B=$2
FORMAT=$3
TOIT=$WT/build/host/sdk/bin/toit
OUT=$A/qemu/insn-$NAME
mkdir -p "$OUT"
PLUGIN=$A/qemu/build/tests/tcg/plugins/libinsn.so
: > "$OUT/summary.txt"
for b in empty richards deltablue pystone json map-set strings gc-stress; do
  TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$OUT/bench-$b.snapshot" "$A/qemu/progs/bench-$b.toit"
  cp "$WT/$B/firmware.envelope" "$OUT/bench-$b.envelope"
  "$TOIT" tool firmware -e "$OUT/bench-$b.envelope" container install bench "$OUT/bench-$b.snapshot"
  bash "$A/scripts/qrun.sh" "$OUT/run-$b.txt" "$B" "$OUT/bench-$b.envelope" -plugin "$PLUGIN" -d plugin > /dev/null
  insns=$(sed -n 's/^total insns: //p' "$OUT/run-$b.txt")
  line=$(grep '^BENCH' "$OUT/run-$b.txt" || echo "BENCH $b MISSING")
  ticks=$(sed -n 's/.* after \([0-9]*\) ticks/\1/p' "$OUT/run-$b.txt")
  echo "$b $insns $ticks $line" | tee -a "$OUT/summary.txt"
done
