#!/usr/bin/env bash
# Usage: bench.sh WORKTREE LABEL
# Runs richards and deltablue in format 2 on the verified run loop
# (TOIT_VERIFY=1), 5 times each, and prints the per-iteration lines.
set -u
WT="$1"
LABEL="$2"
OUT=/home/flo/work/opentoit-sandbox-artifacts/core-refinement/r1/bench
mkdir -p "$OUT"
TOIT="$WT/build/host/sdk/lib/toit/bin/toit.run"
for b in richards deltablue; do
  if [ ! -f "$OUT/$b.snapshot" ]; then
    TOIT_BYTECODE_FORMAT=2 "$TOIT" -w "$OUT/$b.snapshot" "/home/flo/work/benchmarks/toit/$b.toit"
  fi
  for i in 1 2 3 4 5; do
    TOIT_VERIFY=1 "$TOIT" "$OUT/$b.snapshot" 2>&1 | grep "time per" | sed "s/^/$LABEL $b: /"
  done
done
