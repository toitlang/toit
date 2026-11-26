#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: the ESBMC jobs that compile the task/stack allocation
# (item 1 of the coordinator's follow-up). Prints one line per job.
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f
cd "$WT"
export TMPDIR=$WT/build/tmp
run() { verified/cxx/annotated/run.sh "$@" 2>&1 | grep -E "^(ok|FAIL|SKIP|TIMEOUT)"; }
run --slow task-all-fields
run --slow task-retry-fields
run --slow allocate-task
run --slow task-transfer
run --quick task
run --quick initial-task-capacity
run --quick stack
