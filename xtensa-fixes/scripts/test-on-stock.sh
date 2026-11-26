#!/usr/bin/env bash
# Runs new lit tests against the stock llc (llvm-build-stock, unpatched
# 3eeb0284) to show that they fail without the fix. The tests are copied
# into the stock worktree for the run and removed afterwards.
# Usage: test-on-stock.sh <test.ll>...
set -uo pipefail
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes
DST=$ROOT/llvm-project-stock/llvm/test/CodeGen/Xtensa
names=()
for t in "$@"; do
  b=$(basename "$t")
  if [ -e "$DST/$b" ]; then echo "exists in stock: $b"; continue; fi
  cp "$t" "$DST/$b"
  names+=("$b")
done
for b in "${names[@]}"; do
  "$ROOT/llvm-build-stock/bin/llvm-lit" -v "$ROOT/llvm-build-stock/test/CodeGen/Xtensa/$b" 2>&1 \
    | grep -E '^(PASS|FAIL)|error:' | head -4
  rm -f "$DST/$b"
done
