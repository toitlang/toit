#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Captures the serial output of an allowed board.
# Usage: mon.sh PORT CHIP LOG TIMEOUT-S [STOP-REGEX] [--no-reset]
#   Resets the board (esptool hard reset) unless --no-reset, then reads the
#   port at 115200 baud into LOG until STOP-REGEX appears or TIMEOUT-S
#   elapses. Each line is prefixed with the milliseconds since the reset
#   (host clock) when TS=1.
set -uo pipefail
S=$(dirname "$0")
PORT=$1
CHIP=$2
LOG=$3
T=$4
STOP=${5:-}
RESET=1
[ "${6:-}" = --no-reset ] && RESET=0
GUARD_SKIP_CHIP=${GUARD_SKIP_CHIP:-1} "$S/guard.sh" "$PORT" "$CHIP" > /dev/null || exit 1
if [ $RESET = 1 ]; then
  esptool --port "$PORT" --before default-reset --after hard-reset read-mac > "$LOG.reset" 2>&1 || { echo "mon: reset failed"; cat "$LOG.reset"; exit 1; }
fi
stty -F "$PORT" 115200 raw -echo -echoe -echok -echoctl -echoke -icanon -hupcl min 1 time 0 || exit 1
: > "$LOG"
timeout "$T" cat "$PORT" > "$LOG" &
cat_pid=$!
start=$(date +%s)
status=timeout
while kill -0 "$cat_pid" 2> /dev/null; do
  if [ -n "$STOP" ] && grep -a -q -E "$STOP" "$LOG"; then
    sleep 1
    kill "$cat_pid" 2> /dev/null
    status=stopped
    break
  fi
  sleep 0.5
done
wait "$cat_pid" 2> /dev/null
echo "mon: $status after $(( $(date +%s) - start )) s ($(wc -l < "$LOG") lines)"
