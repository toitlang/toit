#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: negative checks of task-all-fields (item 1): each mutant
# puts a bug into a copy of the worktree's sources (build/mut, refreshed from
# the worktree first) and runs the job; each must FAIL.
# Usage: taf-mutants.sh [ABI]   (ILP32 by default)
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f
M=$WT/build/mut
ABI=${1:-ILP32}
export TMPDIR=$WT/build/tmp
fresh() { rsync -a --delete "$WT/src/" "$M/src/"; }
job() {
  local name=$1
  local out
  out=$("$M/verified/cxx/annotated/run.sh" --slow "task-all-fields/$ABI" 2>&1 | grep -E "^(ok|FAIL)")
  echo "$name: $out"
  local log
  log=$(ls -t /home/flo/work/opentoit-sandbox-artifacts/annotated-cxx/work/mut-*/logs/task-all-fields-*.log 2>/dev/null | head -1)
  [ -n "$log" ] && grep -A2 "Violated property" "$log" | sed -n 3p
}
# M1: a format-2 task gets format 1's 64-word stack again.
fresh
sed -i 's/^  Stack\* stack = allocate_stack(Stack::initial_length(program()));$/  Stack* stack = allocate_stack(Stack::initial_length());/' "$M/src/heap.cc"
grep -q "allocate_stack(Stack::initial_length());" "$M/src/heap.cc" || { echo "M1 not applied"; exit 1; }
job "M1 format-1 length"
# M2: the stack's reservation is one word short.
fresh
sed -i 's/^  static word allocation_size(word length) { return HEADER_SIZE + length \* WORD_SIZE; }$/  static word allocation_size(word length) { return HEADER_SIZE + (length - 1) * WORD_SIZE; }/' "$M/src/objects.h"
grep -q "(length - 1) \* WORD_SIZE; }" "$M/src/objects.h" || { echo "M2 not applied"; exit 1; }
job "M2 one word short"
# M3: the format-2 stack slots are not cleared.
fresh
sed -i 's/^    Utils::fill_words<Object\*>(result->_stack_limit_addr(), length, Smi::zero());$/    Utils::fill_words<Object*>(result->_stack_limit_addr(), length - 1, Smi::zero());/' "$M/src/heap.cc"
grep -q "length - 1, Smi::zero()" "$M/src/heap.cc" || { echo "M3 not applied"; exit 1; }
job "M3 one slot not cleared"
fresh
