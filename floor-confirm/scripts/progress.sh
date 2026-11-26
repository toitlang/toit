#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# floor-confirm: a short look at running captures: the last SOAK line, the
# counts of the lines that matter (refusals, evictions, process ends,
# restarts, crashes) and the last heartbeat.
# Usage: progress.sh LOGNAME...   (logs/<LOGNAME>.txt)
set -uo pipefail
L=/home/flo/work/opentoit-sandbox-artifacts/floor-confirm/logs
for n in "$@"; do
  f=$L/$n.txt
  [ -f "$f" ] || { echo "== $n: no log"; continue; }
  echo "== $n ($(wc -l < "$f") lines, last line $(( $(date +%s) - $(tail -1 "$f" | cut -d' ' -f1) )) s ago)"
  grep -a " SOAK t=" "$f" | tail -1 | cut -c1-460
  printf 'starts %s, refused(floor) %s, refused(delay) %s, evictions %s, exits %s, oom-reports %s, sysfail %s, crash %s, uncaught %s\n' \
    "$(grep -a -c '\[toit\] INFO: starting' "$f")" \
    "$(grep -a -c 'sandbox start refused: [0-9]* KB' "$f")" \
    "$(grep -a -c 'sandbox start refused: its last' "$f")" \
    "$(grep -a -c 'stopping sandboxed container' "$f")" \
    "$(grep -a -c 'exited: ' "$f")" \
    "$(grep -a -c 'Heap report @ out of memory' "$f")" \
    "$(grep -a -c 'the operation fails' "$f")" \
    "$(grep -a -c -E 'Guru|abort\(\)|rst:0x|restarting to attempt' "$f")" \
    "$(grep -a -c -E 'Uncaught exception|EXCEPTION error' "$f")"
  grep -a "\[heartbeat\]" "$f" | tail -1
done
