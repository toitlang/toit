#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The images of the churn test (progs/churn, 32-bit):
#   churn-f2.assets: u-exit, u-throw, u-nosvc (untrusted format 2) and
#                    v-exit, v-throw, v-nosvc (trusted format 2)
#   churn-f1.assets: t-exit, t-throw, t-nosvc (trusted format 1)
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ac50d68544beaea91}
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
SRC=$A/progs/churn
OUT=$SRC/images
mkdir -p "$OUT"
TOIT=$WT/build/host/sdk/bin/toit
COMPILE=$WT/build/host/sdk/lib/toit/bin/toit.compile
image() {  # name source compile-args...
  local name=$1 src=$2
  shift 2
  (cd "$SRC" && "$COMPILE" "$@" -w "$OUT/$name.snapshot" "$SRC/$src")
  "$TOIT" tool snapshot-to-image --format=binary -m32 -o "$OUT/$name.image" "$OUT/$name.snapshot"
}
for k in exit throw nosvc; do
  image "u-$k" "x-$k.toit" --untrusted
  image "v-$k" "x-$k.toit"
  image "t-$k" "x-$k.toit" -Xbytecode_format=1
done
for f in 1 2; do
  rm -f "$SRC/churn-f$f.assets"
  "$TOIT" tool assets -e "$SRC/churn-f$f.assets" create
done
for k in exit throw nosvc; do
  "$TOIT" tool assets -e "$SRC/churn-f2.assets" add "u-$k" "$OUT/u-$k.image"
  "$TOIT" tool assets -e "$SRC/churn-f2.assets" add "v-$k" "$OUT/v-$k.image"
  "$TOIT" tool assets -e "$SRC/churn-f1.assets" add "t-$k" "$OUT/t-$k.image"
done
ls -l "$SRC"/*.assets
