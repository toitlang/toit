#!/usr/bin/env bash
# Jaguar (/home/flo/work/jaguar, -O2) as format 1, format 2 and format 2
# without the method table literal: snapshot and 32-bit image sizes.
# Usage: jaguar-sizes.sh
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-aa569f94a56435af9}
A=/home/flo/work/opentoit-sandbox-artifacts/device-size
TOIT=$WT/build/host/sdk/bin/toit
J=/home/flo/work/jaguar
D=$A/jaguar
mkdir -p "$D"
TOIT_BYTECODE_FORMAT=1 "$TOIT" compile -O2 --snapshot --project-root "$J" -o "$D/jaguar-f1.snapshot" "$J/src/jaguar.toit"
TOIT_BYTECODE_FORMAT=2 "$TOIT" compile -O2 --snapshot --project-root "$J" -o "$D/jaguar-f2.snapshot" "$J/src/jaguar.toit"
TOIT_BYTECODE_FORMAT=2 "$TOIT" compile -O2 --snapshot -Xv2_table_literal=false --project-root "$J" -o "$D/jaguar-f2-nolit.snapshot" "$J/src/jaguar.toit"
for f in f1 f2 f2-nolit; do
  "$TOIT" tool snapshot-to-image -m32 --format=binary -o "$D/jaguar-$f.image" "$D/jaguar-$f.snapshot"
  echo "jaguar-$f snapshot $(stat -c %s "$D/jaguar-$f.snapshot") image $(stat -c %s "$D/jaguar-$f.image")"
done
