#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The Verus sections of verified/check.sh, run one at a time: the spec and
# the core at 64-bit words (host) or 32-bit words (i686), the core with the
# features check.sh uses plus any extra `--cfg` arguments (e.g. the loop
# split: 'feature="split-loop"'). Also the --no-cheating log for the audit.
# Usage: verus.sh TAG 64|32 [EXTRA-CORE-CFG...]   (logs in logs/verus-TAG-*.log)
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a1a451d8bc25ddf8a}
A=/home/flo/work/opentoit-sandbox-artifacts/split-option
TAG=$1
W=$2
shift 2
V=$WT/verified
L=$A/logs
OUT=$WT/build/verus-out/$W
mkdir -p "$OUT"
export TMPDIR=$WT/build/tmp
EXTRA=()
for c in "$@"; do EXTRA+=(--cfg "$c"); done
if [ "$W" = 32 ]; then
  T=i686-unknown-linux-gnu
  VERUS=$("$V/tools/verus_target.sh" "$T" "$WT/build/verus-$T") || { echo "no verus for $T"; exit 1; }
  TARGET=(--target "$T")
else
  VERUS=verus
  TARGET=()
fi
res() { grep -E '^verification results:: ' "$1" | tail -1; }
if [ ! -f "$OUT/toit_spec.vir" ] || [ "${SPEC:-0}" = 1 ]; then
  (cd "$V/spec" && "$VERUS" --crate-type=lib "${TARGET[@]}" --crate-name toit_spec \
     --export "$OUT/toit_spec.vir" --compile -o "$OUT/libtoit_spec.rlib" src/lib.rs --time) > "$L/verus-$TAG-spec$W.log" 2>&1
  echo "spec ($W): $(res "$L/verus-$TAG-spec$W.log")"
fi
CORE=(--crate-name toit_verified_core --cfg toit_vcore_hosted --cfg 'feature="checked-loop"' --cfg 'feature="layout-tables"'
      --cfg 'feature="preempt-a-lot"' "${EXTRA[@]}" --extern "toit_spec=$OUT/libtoit_spec.rlib" --import "toit_spec=$OUT/toit_spec.vir")
start=$(date +%s)
(cd "$V/core" && "$VERUS" --crate-type=lib "${TARGET[@]}" "${CORE[@]}" src/lib.rs --time) > "$L/verus-$TAG-core$W.log" 2>&1
echo "core ($W, $*): $(res "$L/verus-$TAG-core$W.log") ($(( $(date +%s) - start )) s)"
if [ "$W" = 64 ]; then
  (cd "$V/core" && verus --crate-type=lib "${CORE[@]}" src/lib.rs --no-cheating --no-verify) > "$L/verus-$TAG-core-nocheat.log" 2>&1 || true
fi
