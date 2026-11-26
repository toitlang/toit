#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The assets of progs/memprobe (32-bit images):
#   memprobe-f2.assets: u-worker, u-idle (untrusted format 2), t2-worker,
#                       t2-idle (trusted format 2)
#   memprobe-f1.assets: t1-worker, t1-idle (trusted format 1)
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f}
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
P=$A/progs/memprobe
OUT=$P/images
mkdir -p "$OUT"
TOIT=$WT/build/host/sdk/bin/toit
COMPILE=$WT/build/host/sdk/lib/toit/bin/toit.compile
image() {  # name source compile-args...
  local name=$1 src=$2
  shift 2
  (cd "$P" && "$COMPILE" "$@" -w "$OUT/$name.snapshot" "$P/$src")
  "$TOIT" tool snapshot-to-image --format=binary -m32 -o "$OUT/$name.image" "$OUT/$name.snapshot"
}
image u-worker soak-worker.toit --untrusted
image u-idle idle.toit --untrusted
image t2-worker soak-worker.toit -Xbytecode_format=2
image t2-idle idle.toit -Xbytecode_format=2
image t1-worker soak-worker.toit -Xbytecode_format=1
image t1-idle idle.toit -Xbytecode_format=1
mk() {  # assets names...
  local f=$1
  shift
  rm -f "$P/$f"
  "$TOIT" tool assets -e "$P/$f" create
  for n in "$@"; do "$TOIT" tool assets -e "$P/$f" add "$n" "$OUT/$n.image"; done
}
mk memprobe-f2.assets u-idle u-worker t2-idle t2-worker
mk memprobe-f1.assets t1-idle t1-worker
ls -l "$OUT"/*.image "$P"/*.assets
