#!/usr/bin/env bash
# Image breakdown of snapshots (toolsrc/image-breakdown.toit), side by side.
# Usage: img.sh SNAPSHOT...
set -euo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/compact-methods/dev
TOIT=${TOIT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a3d099a7d850ef2fb/build/host/sdk/bin/toit}
files=()
for s in "$@"; do
  out=$(mktemp)
  "$TOIT" run "$A/toolsrc/image-breakdown.toit" "$s" | awk '{ print $1 }' > "$out"
  files+=("$out")
done
names=$(mktemp)
"$TOIT" run "$A/toolsrc/image-breakdown.toit" "$1" | sed -E 's/^ *[0-9]+  //' > "$names"
paste "${files[@]}" "$names" | awk -F'\t' '{ line = ""; for (i = 1; i < NF; i++) line = line sprintf("%9s ", $i); print line " " $NF }'
rm -f "${files[@]}" "$names"
