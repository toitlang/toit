#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Compiles Jaguar (/home/flo/work/jaguar, -O2) with the worktree's host SDK as
# format 1 and format 2 snapshots (jaguar/jaguar-f1.snapshot, -f2.snapshot)
# and prints the snapshot and 32-bit image sizes.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ac50d68544beaea91
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
TOIT=$WT/build/host/sdk/bin/toit
J=/home/flo/work/jaguar
D=$A/jaguar
export TMPDIR=$WT/build/tmp
mkdir -p "$D"
TOIT_BYTECODE_FORMAT=1 "$TOIT" compile -O2 --snapshot --project-root "$J" -o "$D/jaguar-f1.snapshot" "$J/src/jaguar.toit"
TOIT_BYTECODE_FORMAT=2 "$TOIT" compile -O2 --snapshot --project-root "$J" -o "$D/jaguar-f2.snapshot" "$J/src/jaguar.toit"
for f in f1 f2; do
  "$TOIT" tool snapshot-to-image -m32 --format=binary -o "$D/jaguar-$f.image" "$D/jaguar-$f.snapshot"
  echo "jaguar-$f snapshot $(stat -c %s "$D/jaguar-$f.snapshot") image $(stat -c %s "$D/jaguar-$f.image")"
done
