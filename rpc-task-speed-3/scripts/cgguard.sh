#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Host instruction count (callgrind) of progs/host/opbench.toit (the guard
# benchmarks: richards, deltablue, pystone, json, ...) in format 2 on the
# worktree's host build: a proxy for "nothing else got slower".
# Usage: cgguard.sh TAG   -> logs/cg-guard-TAG.txt
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a063f79f8b4a649b9
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-3
TAG=$1
F=${2:-2}
export TMPDIR=$WT/build/tmp
BIN=$WT/build/host/sdk/lib/toit/bin
SNAP=$TMPDIR/opbench-$TAG-f$F.snap
"$BIN/toit.compile" -Xbytecode_format="$F" -w "$SNAP" "$A/progs/host/opbench.toit"
OUT=$A/logs/cg/guard-$TAG-f$F.out
valgrind --tool=callgrind --callgrind-out-file="$OUT" "$BIN/toit.run" "$SNAP" > "$OUT.log" 2>&1
ir=$(sed -n 's/^summary: //p; s/^totals: //p' "$OUT" | head -1)
echo "$TAG f$F opbench Ir $ir" | tee "$A/logs/cg-guard-$TAG-f$F.txt"
