#!/usr/bin/env bash
# Builds llc for each fix branch of the LLVM clone in the shared build tree
# and keeps a copy per branch under llc-bin/<branch>/bin/llc, so that the
# exposure scan can attribute a code difference to one fix.
# Usage: build-llc-per-fix.sh <branch>...
set -euo pipefail
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes
for br in "$@"; do
  git -C "$ROOT/llvm-project" checkout -q "$br"
  ninja -C "$ROOT/llvm-build" -j30 llc > "$ROOT/llvm-build/build-$br.log" 2>&1
  mkdir -p "$ROOT/llc-bin/$br/bin"
  cp "$ROOT/llvm-build/bin/llc" "$ROOT/llc-bin/$br/bin/llc"
  echo "$br: $(git -C "$ROOT/llvm-project" rev-parse --short HEAD)"
done
