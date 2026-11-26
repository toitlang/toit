#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# liveness: runs the provider-out-of-memory stress program (progs/host/
# rpc-provider-oom-stress.toit) N times with the RPC library files of a
# revision (REV, default: the working tree) and tallies the outcomes (ok,
# lost: a call got no reply although the provider answers; stuck: the
# provider doesn't answer; died: the provider process ended).
# Usage: stress.sh N [REV]
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a0319253ba15c69bc
A=/home/flo/work/opentoit-sandbox-artifacts/liveness
N=$1
REV=${2:-}
cd "$WT"
export TMPDIR=$WT/build/tmp
FILES="lib/core/message_.toit lib/core/task.toit lib/core/monitor_impl_.toit lib/rpc/broker.toit lib/rpc/rpc.toit lib/system/trace.toit"
save=$TMPDIR/stress-save
if [ -n "$REV" ]; then
  mkdir -p "$save"
  for f in $FILES; do mkdir -p "$save/$(dirname "$f")"; cp "$f" "$save/$f"; git show "$REV:$f" > "$f"; done
  trap 'for f in $FILES; do cp "$save/$f" "$f"; done' EXIT
fi
for i in $(seq "$N"); do
  out=$(timeout 200 build/host/sdk/bin/toit run "$A/progs/host/rpc-provider-oom-stress.toit" 2>&1 | grep -a "OUTCOME\|Uncaught" | head -3)
  [ -z "$out" ] && out="OUTCOME none"
  echo "$out"
done | tee "$A/logs/stress-${REV:-head}.txt" | sed 's/OUTCOME \([a-z-]*\).*/\1/; s/Uncaught exception: .*/uncaught/' | sort | uniq -c
