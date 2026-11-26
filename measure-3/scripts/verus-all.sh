#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The Verus sections of verified/check.sh, one at a time, on a snapshot of a
# commit (git archive, build/vsnap/SHA): spec, core, core-split at 64 and
# 32 bits (the same arguments as check.sh), and the --no-cheating logs of
# the 64-bit runs for the escape-hatch audit.
# Usage: verus-all.sh TAG [REF]   (logs: logs/verus-TAG-*.log)
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a8cbed86ae1ed9653}
A=/home/flo/work/opentoit-sandbox-artifacts/measure-3
TAG=$1
REF=${2:-HEAD}
cd "$WT" || exit 1
SHA=$(git rev-parse --short "$REF")
S=$WT/build/vsnap/$SHA
if [ ! -d "$S/verified" ]; then
  mkdir -p "$S"
  git archive "$SHA" verified | tar -x -C "$S"
fi
V=$S/verified
export TMPDIR=$WT/build/tmp
res() { grep -E '^verification results:: ' "$1" | tail -1; }
for W in 64 32; do
  OUT=$S/out$W
  mkdir -p "$OUT"
  if [ "$W" = 32 ]; then
    T=i686-unknown-linux-gnu
    VERUS=$("$WT/verified/tools/verus_target.sh" "$T" "$WT/build/verus-$T") || { echo "no verus for $T"; exit 1; }
    TARGET=(--target "$T")
  else
    VERUS=verus
    TARGET=()
  fi
  L=$A/logs/verus-$TAG-spec$W.log
  (cd "$V/spec" && "$VERUS" --crate-type=lib "${TARGET[@]}" --crate-name toit_spec \
     --export "$OUT/toit_spec.vir" --compile -o "$OUT/libtoit_spec.rlib" src/lib.rs --time) > "$L" 2>&1
  echo "spec ($W, $SHA): $(res "$L")"
  CORE=(--crate-name toit_verified_core --cfg toit_vcore_hosted --cfg 'feature="checked-loop"' --cfg 'feature="layout-tables"'
        --cfg 'feature="preempt-a-lot"' --extern "toit_spec=$OUT/libtoit_spec.rlib" --import "toit_spec=$OUT/toit_spec.vir")
  for C in core core-split; do
    EXTRA=()
    [ "$C" = core-split ] && EXTRA=(--cfg 'feature="split-loop"')
    L=$A/logs/verus-$TAG-$C$W.log
    start=$(date +%s)
    (cd "$V/core" && "$VERUS" --crate-type=lib "${TARGET[@]}" "${CORE[@]}" "${EXTRA[@]}" src/lib.rs --time) > "$L" 2>&1
    echo "$C ($W, $SHA): $(res "$L") ($(( $(date +%s) - start )) s)"
    if [ "$W" = 64 ]; then
      (cd "$V/core" && verus --crate-type=lib "${CORE[@]}" "${EXTRA[@]}" src/lib.rs --no-cheating --no-verify) > "$A/logs/verus-$TAG-$C.nocheat.log" 2>&1 || true
    fi
  done
  if [ "$W" = 64 ]; then
    (cd "$V/spec" && verus --crate-type=lib --crate-name toit_spec src/lib.rs --no-cheating --no-verify) > "$A/logs/verus-$TAG-spec.nocheat.log" 2>&1 || true
  fi
done
