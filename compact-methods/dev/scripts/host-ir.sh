#!/usr/bin/env bash
# Host speed check: callgrind Ir inside toit::Interpreter::run() for
# richards, deltablue and pystone compiled with the worktree's SDK (format 2,
# trusted: the compiler's default), as verified/core/EXPERIMENT-trusted.md.
# Usage: host-ir.sh LABEL
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a3d099a7d850ef2fb
A=/home/flo/work/opentoit-sandbox-artifacts/compact-methods/dev
BIN=$WT/build/host/sdk/lib/toit/bin
mkdir -p "$A/ir"
for b in richards deltablue pystone; do
  (
    "$BIN/toit.compile" -w "$A/ir/$b.snap" "/home/flo/work/benchmarks/toit/$b.toit"
    f="$A/ir/cg.$1.$b"
    rm -f "$f".*
    valgrind --tool=callgrind '--toggle-collect=toit::Interpreter::run()' --callgrind-out-file="$f.%p" \
      "$BIN/toit.run" "$A/ir/$b.snap" > "$f.out" 2>&1
    ir=$(cat "$f".[0-9]* | awk '/^summary:/ { s += $2 } END { print s + 0 }')
    echo "$1 $b $ir"
  ) &
done | sort | tee -a "$A/ir/results.txt"
wait
