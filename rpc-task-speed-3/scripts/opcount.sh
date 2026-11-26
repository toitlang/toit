#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Dynamic format-2 opcode counts per benchmark of progs/host/opbench.toit:
# compiles it as a trusted format-2 snapshot (as the device's first-party
# containers) with the debug host build (build/dbg), runs it on the checked
# loop with -Xtrace and counts "#opcode" lines between "OPB name" markers.
# Output: logs/opcounts.txt ("bench opcode count" lines).
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a063f79f8b4a649b9
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-3
BIN=$WT/build/dbg/sdk/lib/toit/bin
export TMPDIR=$WT/build/tmp
SNAP=$TMPDIR/opbench-f2t.snap
TOIT_V2_UNCHECKED=1 "$BIN/toit.compile" -Xbytecode_format=2 -w "$SNAP" "$A/progs/host/opbench.toit" || exit 1
TOIT_TRUSTED_CHECKED_LOOP=1 "$BIN/toit.run" -Xtrace "$SNAP" 2> "$A/logs/opcount.stderr" |
  awk '/^OPB / { cur = $2; next }
       cur != "-" && cur != "" && /^\[ *[0-9]+\] #[0-9]+$/ { c[cur " " substr($NF, 2)]++ }
       END { for (k in c) print k, c[k] }' | sort -k1,1 -k3,3nr > "$A/logs/opcounts.txt"
wc -l < "$A/logs/opcounts.txt"
