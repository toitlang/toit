#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Runs a program of this directory on the host with an experimental copy of
# the library (LIB, default: the worktree's build/tmp/libexp).
# Usage: run-exp.sh PROGRAM FORMAT WORKERS HEAP UNTRUSTED SECONDS
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ac50d68544beaea91
export TMPDIR=$WT/build/tmp
LIB=${LIB:-$WT/build/tmp/libexp}
RUN=$WT/build/host/sdk/lib/toit/bin/toit.run
cd "$(dirname "$0")" || exit 1
unchecked=0
[ "$2" = 1 ] && unchecked=1
TOIT_BYTECODE_FORMAT=$2 TOIT_V2_UNCHECKED=$unchecked timeout $(( $6 + 30 )) "$RUN" -Xlib_path="$LIB" "$1" "$3" "$4" "$5" "$6" 2>&1 | grep -v "^Out of memory process"
