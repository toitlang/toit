#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# f2 checksum of the primitive differential after exactly K calls (one print),
# to bisect against the f1 checksums of pdiff-fine (every 100 calls).
# Usage: pdiff-at.sh SEED N K
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
TOIT=$WT/build/host/sdk/bin/toit
SEED=$1; N=$2; K=$3
OUT=$A/qemu/pdiff-at
mkdir -p "$OUT"
P=$A/qemu/progs/pdiff-at-$SEED-$K.toit
perl -pe "s/if \\(iteration \\+ 1\\) % 10_000 == 0:/if (iteration + 1) == $K:/" "$A/qemu/progs/primitive-diff.toit" > "$A/qemu/progs/pdiff-at-impl-$K.toit"
printf 'import .pdiff-at-impl-%s as diff\nmain:\n  diff.main ["%s", "%s"]\n' "$K" "$SEED" "$N" > "$P"
TOIT_BYTECODE_FORMAT=2 "$TOIT" compile --snapshot -o "$OUT/$SEED-$K.snapshot" "$P"
cp "$WT/build/ec618-f2/firmware.envelope" "$OUT/$SEED-$K.envelope"
"$TOIT" tool firmware -e "$OUT/$SEED-$K.envelope" container install diff "$OUT/$SEED-$K.snapshot"
bash "$A/scripts/qrun.sh" "$OUT/$SEED-$K.txt" build/ec618-f2 "$OUT/$SEED-$K.envelope" > /dev/null
got=$(grep -a "^checksum $K " "$OUT/$SEED-$K.txt" | awk '{print $3}')
want=$(grep -a "^checksum $K " "$A/qemu/pdiff-fine/seed$SEED-f1.sums" | awk '{print $3}')
if [ "$got" = "$want" ]; then echo "$K same"; else echo "$K DIFF ($got vs $want)"; fi
