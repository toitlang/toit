#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The escape-hatch audit section of verified/check.sh on its own: Verus'
# --no-cheating logs of spec, core and core-split (as check.sh makes them),
# then verified/tools/trust_audit.toit against verified/TRUSTED.toml.
# Needs the spec's .vir/.rlib from verus.sh (build/verus-out/64).
# Usage: audit.sh TAG   (log: logs/audit-TAG.txt)
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a317ce7f79e57a075
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-2
TAG=$1
V=$WT/verified
OUT=$WT/build/verus-out/64
L=$WT/build/tmp/audit-$TAG
mkdir -p "$L"
export TMPDIR=$WT/build/tmp
CORE=(--crate-name toit_verified_core --cfg toit_vcore_hosted --cfg 'feature="checked-loop"' --cfg 'feature="layout-tables"'
      --cfg 'feature="preempt-a-lot"' --extern "toit_spec=$OUT/libtoit_spec.rlib" --import "toit_spec=$OUT/toit_spec.vir")
(cd "$V/spec" && verus --crate-type=lib --crate-name toit_spec src/lib.rs --no-cheating --no-verify) > "$L/spec.nocheat.log" 2>&1
(cd "$V/core" && verus --crate-type=lib "${CORE[@]}" src/lib.rs --no-cheating --no-verify) > "$L/core.nocheat.log" 2>&1
(cd "$V/core" && verus --crate-type=lib "${CORE[@]}" --cfg 'feature="split-loop"' src/lib.rs --no-cheating --no-verify) > "$L/core-split.nocheat.log" 2>&1
"$WT/build/host/sdk/bin/toit" run "$V/tools/trust_audit.toit" -- --root "$V" \
  --verus-no-cheating-log "spec=$L/spec.nocheat.log" \
  --verus-no-cheating-log "core=$L/core.nocheat.log" \
  --verus-no-cheating-log "core=$L/core-split.nocheat.log" > "$A/logs/audit-$TAG.txt" 2>&1
rc=$?
tail -5 "$A/logs/audit-$TAG.txt"
echo "audit exit $rc"
exit $rc
