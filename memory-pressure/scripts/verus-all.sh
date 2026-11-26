#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: the gate sections verus, audit (64-bit) and verus32 of the
# worktree, logs in logs/check-*-TAG.log, then the counts and whether
# THEOREMS.txt changed. Usage: verus-all.sh TAG
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
TAG=$1
cd "$WT"
export TMPDIR=$WT/build/tmp
verified/check.sh --only verus,audit --logs build/verus-logs > "$A/logs/check-verus-audit-$TAG.log" 2>&1
verified/check.sh --only verus32 --logs build/verus-logs32 > "$A/logs/check-verus32-$TAG.log" 2>&1
grep -h -E "verified,|audit:|passed|FAIL|error" "$A/logs/check-verus-audit-$TAG.log" "$A/logs/check-verus32-$TAG.log"
echo "THEOREMS.txt: $(git diff --stat verified/THEOREMS.txt | tail -1)"
