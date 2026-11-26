#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# x86-64 instructions of one toit_vmverify_verify call (callgrind, the
# host bench vbench with the saved certificate) per program, and the
# allocation count. Usage: icount.sh TAG [PROGRAM...] (default a-hello c-map g-big)
# Profiles stay in build/prof/cg-TAG-PROGRAM.out.
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ab8ae657bf5edfc00}
P=$WT/build/prof
B=$WT/build/vbench/release/vbench
TAG=$1
shift
PROGS=${*:-a-hello c-map g-big}
export TMPDIR=$WT/build/tmp
for p in $PROGS; do
  out=$P/cg-$TAG-$p.out
  line=$(valgrind --tool=callgrind --callgrind-out-file="$out" --toggle-collect=toit_vmverify_verify \
    "$B" --runs 1 --cert "$P/$p.tables.cert" "$P/$p.tables" 2>&1)
  coll=$(printf '%s\n' "$line" | sed -n 's/.*Collected : \([0-9]*\).*/\1/p')
  allocs=$(printf '%s\n' "$line" | sed -n 's/.*allocations \([0-9]*\).*/\1/p')
  code=$(printf '%s\n' "$line" | sed -n 's/.*: code \([0-9]*\).*/\1/p')
  printf '%-8s %-8s code %s  instructions/call %d  allocations %s\n' "$TAG" "$p" "$code" $((coll / 2)) "$allocs"
done
