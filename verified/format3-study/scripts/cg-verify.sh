#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# x86-64 instructions (callgrind Ir) of one certificate check per program
# and checker (f3study verify MODE 1 TABLES; only the measure_* function is
# collected): shipped = today's proven verify_shipped, fused / fused-inc =
# the unproved single-pass prototypes (verified/format3-study/src/fused.rs).
# Trusted programs (compiled with the unchecked twins) are checked with the
# trusted rules (F3STUDY_TRUSTED).
# Usage: cg-verify.sh [PROGRAMS...]   Output: logs/cg-verify.txt
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a8868e80a23e89460}
A=/home/flo/work/opentoit-sandbox-artifacts/format3-study
F=$WT/build/f3study/release/f3study
export TMPDIR=$WT/build/tmp
mkdir -p "$A/logs/cg"
PROGS=${*:-a-hello c-map g-big taskbench opbench esp32-system}
MODES=${MODES:-shipped fused fused-inc}
OUT=$A/logs/cg-verify.txt
: > "$OUT"
for p in $PROGS; do
  envs=()
  case $p in a-hello|c-map|g-big) ;; *) envs=(F3STUDY_TRUSTED=1) ;; esac
  for m in $MODES; do
    o=$A/logs/cg/verify-$m-$p.out
    line=$(env "${envs[@]}" valgrind --tool=callgrind --callgrind-out-file="$o" --toggle-collect='*measure_*' \
      "$F" verify "$m" 1 "$A/data/$p.tables" 2>&1)
    ir=$(printf '%s\n' "$line" | sed -n 's/.*Collected : \([0-9]*\).*/\1/p')
    res=$(printf '%s\n' "$line" | grep -o 'ok [a-z]* bytecodes [0-9]*.*allocations/run [0-9]* peak [0-9]* B')
    echo "$p $m Ir $ir $res" | tee -a "$OUT"
  done
done
