#!/usr/bin/env bash
# Usage: ir.sh WORKTREE LABEL
# Instruction counts (callgrind) of richards and deltablue in format 2 on
# the verified run loop (TOIT_VERIFY=1).
set -u
WT="$1"
LABEL="$2"
OUT=/home/flo/work/opentoit-sandbox-artifacts/core-refinement/r1/bench
TOIT="$WT/build/host/sdk/lib/toit/bin/toit.run"
for b in richards deltablue; do
  n=$(TOIT_VERIFY=1 valgrind --tool=callgrind --callgrind-out-file=/dev/null "$TOIT" "$OUT/$b.snapshot" 2>&1 | grep -E "Collected" | awk '{print $4}')
  echo "$LABEL $b Ir $n"
done
