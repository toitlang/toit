#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: runs ESBMC on the task-all-fields job of the worktree by
# hand (the command of verified/cxx/annotated/run.sh's cpp_equivalence for
# `instance_allocation task-all-fields ILP32 32 allocate_task
# -DCXXV_SYMBOLIC_FIELDS --unwind 10`), with extra ESBMC options.
# Usage: esbmc-taf.sh BITS LOG [EXTRA ESBMC OPTIONS...]
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f
BITS=$1
LOG=$2
shift 2
# shellcheck disable=SC1091
source "$WT/verified/cxx/env.sh"
INC=/home/flo/work/opentoit-sandbox-artifacts/annotated-cxx/work/agent-a2ae466cd9dbd080f-2605626442/task-all-fields-$BITS
cd "$WT/verified/cxx/annotated"
mkdir -p "$INC"
awk '{ replaced += sub(/Utils::fill_words<Object\*>\(fields,/, "apply_field_fill(fields,"); print }
     END { if (replaced != 1) exit 1 }' "$WT/src/heap.cc" > "$INC/instance_heap.inc"
timeout 1800 "$ESBMC" ../harness/allocate_task.cc "${CXXV_FLAGS[@]}" --std c++11 -DTOIT_VERIFIED_CORE \
  "--$BITS" "-DCXXV_WORD_BITS=$BITS" --overflow-check "-I$INC" -DCXXV_SYMBOLIC_FIELDS --unwind 10 "$@" > "$LOG" 2>&1
grep -E "VERIFICATION (SUCCESSFUL|FAILED)|properties failed" "$LOG" | tail -2
