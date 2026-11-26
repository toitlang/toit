#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Host instruction counts (callgrind) of progs/host/taskbench.toit.
# Usage: hostcount.sh SDK-ROOT FORMAT BENCH N [TAG]
#   SDK-ROOT: a host build's root (e.g. <worktree>/build/host); its compiler
#   compiles the benchmark as a trusted snapshot of FORMAT (1 or 2).
#   Prints "TAG fFORMAT BENCH N Ir" and keeps the callgrind output in
#   logs/cg/TAG-fFORMAT-BENCH-N.out (callgrind_annotate it for the functions).
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a317ce7f79e57a075
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-2
ROOT=$1
F=$2
BENCH=$3
N=$4
TAG=${5:-$(basename "$(dirname "$(dirname "$ROOT")")")}
export TMPDIR=$WT/build/tmp
mkdir -p "$TMPDIR" "$A/logs/cg"
BIN=$ROOT/sdk/lib/toit/bin
SNAP=$TMPDIR/taskbench-$TAG-f$F.snap
if [ ! -f "$SNAP" ] || [ "$SNAP" -ot "$A/progs/host/taskbench.toit" ] || [ "$SNAP" -ot "$BIN/toit.run" ]; then
  "$BIN/toit.compile" -Xbytecode_format="$F" -w "$SNAP" "$A/progs/host/taskbench.toit"
fi
OUT=$A/logs/cg/$TAG-f$F-$BENCH-$N.out
valgrind --tool=callgrind --callgrind-out-file="$OUT" "$BIN/toit.run" "$SNAP" "$BENCH" "$N" > "$OUT.log" 2>&1
ir=$(sed -n 's/^summary: //p; s/^totals: //p' "$OUT" | head -1)
echo "$TAG f$F $BENCH $N $ir"
