#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The assets of the soak controller (progs/soak, 32-bit images):
#   soak-f2.assets: u-worker (soak-worker.toit, untrusted format 2 with its
#                   certificate), u-hello, u-map, u-big (the untrusted
#                   a-hello, c-map, g-big of progs/untrusted)
#   soak-f1.assets: t-worker, t-hello, t-map, t-big (the same programs,
#                   trusted format 1)
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a0319253ba15c69bc}
A=/home/flo/work/opentoit-sandbox-artifacts/liveness
OUT=$A/progs/soak/images
mkdir -p "$OUT"
TOIT=$WT/build/host/sdk/bin/toit
COMPILE=$WT/build/host/sdk/lib/toit/bin/toit.compile
image() {  # name dir source compile-args...
  local name=$1 dir=$2 src=$3
  shift 3
  (cd "$dir" && "$COMPILE" "$@" -w "$OUT/$name.snapshot" "$dir/$src")
  "$TOIT" tool snapshot-to-image --format=binary -m32 -o "$OUT/$name.image" "$OUT/$name.snapshot"
}
U=$A/progs/untrusted-src
image u-worker "$A/progs/soak" soak-worker.toit --untrusted
image t-worker "$A/progs/soak" soak-worker.toit -Xbytecode_format=1
image t-hello "$U" hello.toit -Xbytecode_format=1
image t-map "$U" map-test.toit -Xbytecode_format=1
image t-big "$U" big.toit -Xbytecode_format=1
cp "$A/progs/untrusted/a-hello.image" "$OUT/u-hello.image"
cp "$A/progs/untrusted/c-map.image" "$OUT/u-map.image"
cp "$A/progs/untrusted/g-big.image" "$OUT/u-big.image"
for f in 1 2; do
  [ $f = 1 ] && p=t || p=u
  rm -f "$A/progs/soak/soak-f$f.assets"
  "$TOIT" tool assets -e "$A/progs/soak/soak-f$f.assets" create
  for n in worker hello map big; do
    "$TOIT" tool assets -e "$A/progs/soak/soak-f$f.assets" add "$p-$n" "$OUT/$p-$n.image"
  done
done
ls -l "$OUT"/*.image "$A"/progs/soak/*.assets
