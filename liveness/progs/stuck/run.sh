#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Runs stuck.toit on the host. Usage: run.sh FORMAT WORKERS HEAP UNTRUSTED SECONDS [TOIT]
# (FORMAT 1 or 2; TOIT defaults to the worktree's SDK.)
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f
export TMPDIR=$WT/build/tmp
T=${6:-$WT/build/host/sdk/bin/toit}
cd "$(dirname "$0")" || exit 1
unchecked=0
[ "$1" = 1 ] && unchecked=1
TOIT_BYTECODE_FORMAT=$1 TOIT_V2_UNCHECKED=$unchecked timeout $(( $5 + 30 )) "$T" run stuck.toit "$2" "$3" "$4" "$5" 2>&1 | grep -v "^Out of memory process"
