#!/usr/bin/env bash
# Adds the QEMU suite containers (suite with the untrusted images as assets,
# provider, thrower) to a firmware envelope, compiled in the given bytecode
# format. Usage: suite-envelope.sh IN-ENVELOPE OUT-ENVELOPE FORMAT [SUITE-SOURCE]
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a063f79f8b4a649b9}
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-3
IN=$1
OUT=$2
FORMAT=$3
SUITE=${4:-$A/progs/suite/suite.toit}
TOIT=$WT/build/host/sdk/bin/toit
D=$(dirname "$OUT")/snapshots-f$FORMAT
mkdir -p "$D"
for p in "$SUITE" "$A/progs/suite/provider.toit" "$A/progs/suite/thrower.toit" "$A/progs/suite/spinner.toit"; do
  name=$(basename "$p" .toit)
  TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/$name.snapshot" "$p"
done
cp "$IN" "$OUT"
"$TOIT" tool firmware -e "$OUT" container install --assets "$A/progs/untrusted/untrusted.assets" suite "$D/$(basename "$SUITE" .toit).snapshot"
"$TOIT" tool firmware -e "$OUT" container install --trigger none provider "$D/provider.snapshot"
"$TOIT" tool firmware -e "$OUT" container install --trigger none thrower "$D/thrower.snapshot"
"$TOIT" tool firmware -e "$OUT" container install --trigger none spinner "$D/spinner.snapshot"
