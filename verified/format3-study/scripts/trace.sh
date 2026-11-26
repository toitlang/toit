#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Dynamic statistics (f3study trace) of the study's benchmarks: compiles a
# program as a trusted format-2 snapshot with the debug host build
# (build/dbg: -Xtrace exists only there), saves its tables with the same
# build, runs it on the checked loop with -Xtrace and TOIT_V2_TRACE_PROCESS
# (each line names the process and program) and pipes the trace into
# f3study (no trace is stored).
# Usage: trace.sh NAME SOURCE [ARGS...]   Output: logs/trace-NAME.txt
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a8868e80a23e89460}
A=/home/flo/work/opentoit-sandbox-artifacts/format3-study
BIN=$WT/build/dbg/sdk/lib/toit/bin
F=$WT/build/f3study/release/f3study
export TMPDIR=$WT/build/tmp
NAME=$1
SRC=$2
shift 2
D=$A/data/dbg
mkdir -p "$D"
SNAP=$D/$NAME.snapshot
(cd "$(dirname "$SRC")" && TOIT_V2_UNCHECKED=1 "$BIN/toit.compile" -Xbytecode_format=2 -w "$SNAP" "$SRC") || exit 1
"$BIN/toit.run" --verify --emit-canonical="$D/$NAME.tables" "$SNAP" > /dev/null 2>&1
TOIT_V2_TRACE_PROCESS=1 TOIT_TRUSTED_CHECKED_LOOP=1 "$BIN/toit.run" -Xtrace "$SNAP" "$@" 2> "$A/logs/trace-$NAME.stderr" |
  F3STUDY_TRUSTED=1 "$F" trace "$D/$NAME.tables" 60 > "$A/logs/trace-$NAME.txt" 2>> "$A/logs/trace-$NAME.stderr"
head -1 "$A/logs/trace-$NAME.txt"
grep "^== dynamic" "$A/logs/trace-$NAME.txt"
