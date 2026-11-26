#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Host instruction counts per iteration (callgrind, hostcount.sh) of the
# task ping-pong, yield, RPC and echo benchmarks for format 1 and 2 of one
# host build: (Ir(N) - Ir(0)) / N.
# Usage: cgmatrix.sh TAG [FORMATS] [BENCHES]   (default "1 2", "tasks yield rpc echo")
# Output: logs/cg-matrix-TAG.txt
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a317ce7f79e57a075
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-2
TAG=$1
FORMATS=${2:-1 2}
BENCHES=${3:-tasks yield rpc echo}
OUT=$A/logs/cg-matrix-$TAG.txt
: > "$OUT"
for f in $FORMATS; do
  for b in $BENCHES; do
    case $b in
      tasks) n=1000 ;; yield) n=2000 ;; rpc) n=200 ;; echo) n=50 ;;
    esac
    i0=$(bash "$A/scripts/hostcount.sh" "$WT/build/host" "$f" "$b" 0 "$TAG" | awk '{print $5}')
    i1=$(bash "$A/scripts/hostcount.sh" "$WT/build/host" "$f" "$b" "$n" "$TAG" | awk '{print $5}')
    echo "$TAG f$f $b n=$n per-iter $(( (i1 - i0) / n )) (Ir $i0 / $i1)" | tee -a "$OUT"
  done
done
