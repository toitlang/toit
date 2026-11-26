#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Verus on verified/spec only (check.sh's spec section), 64- or 32-bit words,
# on a snapshot of a commit (git archive), so the worktree can change meanwhile.
# Usage: specverus.sh TAG 64|32 [REF]   (REF default HEAD; log:
# logs/verus-TAG-spec{64,32}.log; the exported .vir/.rlib go to
# build/vsnap/SHA/out{64,32} for corever.sh)
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a8cbed86ae1ed9653}
A=/home/flo/work/opentoit-sandbox-artifacts/measure-3
TAG=$1
W=$2
REF=${3:-HEAD}
cd "$WT" || exit 1
SHA=$(git rev-parse --short "$REF")
S=$WT/build/vsnap/$SHA
if [ ! -d "$S/verified" ]; then
  mkdir -p "$S"
  git archive "$SHA" verified | tar -x -C "$S"
fi
V=$S/verified
OUT=$S/out$W
mkdir -p "$OUT"
export TMPDIR=$WT/build/tmp
if [ "$W" = 32 ]; then
  T=i686-unknown-linux-gnu
  VERUS=$("$WT/verified/tools/verus_target.sh" "$T" "$WT/build/verus-$T") || { echo "no verus for $T"; exit 1; }
  TARGET=(--target "$T")
else
  VERUS=verus
  TARGET=()
fi
LOG=$A/logs/verus-$TAG-spec$W.log
start=$(date +%s)
(cd "$V/spec" && "$VERUS" --crate-type=lib "${TARGET[@]}" --crate-name toit_spec \
   --export "$OUT/toit_spec.vir" --compile -o "$OUT/libtoit_spec.rlib" src/lib.rs --time) > "$LOG" 2>&1
echo "spec ($W, $TAG, $SHA): $(grep -E '^verification results:: ' "$LOG" | tail -1) ($(( $(date +%s) - start )) s)"
grep -E '^error' -A12 "$LOG" | head -60
true
