#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Runs stuck.toit under gdb (toit.run), interrupts it after DELAY seconds
# and prints the backtraces of all threads.
# Usage: gdb.sh FORMAT DELAY [TOIT.RUN]
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ac50d68544beaea91
export TMPDIR=$WT/build/tmp
RUN=${3:-$WT/build/host/sdk/lib/toit/bin/toit.run}
cd "$(dirname "$0")" || exit 1
unchecked=0
[ "$1" = 1 ] && unchecked=1
(
  sleep "$2"
  pkill -INT -x toit.run -P $$ 2> /dev/null || true
  for p in $(pgrep -x toit.run); do
    # Only our own inferior: its parent is the gdb started below.
    pp=$(ps -o ppid= -p "$p" | tr -d ' ')
    if [ "$(ps -o comm= -p "$pp")" = gdb ] && [ "$(ps -o ppid= -p "$pp" | tr -d ' ')" = $$ ]; then
      kill -INT "$p"
    fi
  done
) &
TOIT_BYTECODE_FORMAT=$1 TOIT_V2_UNCHECKED=$unchecked gdb -batch -q \
  -ex "set pagination off" -ex "handle SIGPIPE nostop noprint" -ex "handle SIGUSR1 nostop noprint" \
  -ex run -ex "thread apply all bt 30" -ex kill \
  --args "$RUN" stuck.toit 3 100000 1 60 2>&1 | grep -v "^Out of memory process"
wait
