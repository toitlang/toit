#!/usr/bin/env bash
# Decodes every "jag decode" system message of a serial log with the
# snapshots of a directory (the one whose uuid matches the message).
# Usage: decode.sh SERIAL-TXT SNAPSHOT-DIR...
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a317ce7f79e57a075}
TOIT=$WT/build/host/sdk/bin/toit
SERIAL=$1
shift
n=0
grep -a "^jag decode " "$SERIAL" | sed 's/^jag decode //' | while read -r msg; do
  n=$((n + 1))
  echo "== message $n"
  done_one=0
  for dir in "$@"; do
    for snap in "$dir"/*.snapshot; do
      out=$("$TOIT" decode --force-plain -s "$snap" "$msg" 2>&1)
      if ! grep -q "WARNING" <<< "$out"; then
        echo "$out"
        done_one=1
        break 2
      fi
    done
  done
  [ $done_one = 1 ] || "$TOIT" decode --force-plain "$msg"
done
