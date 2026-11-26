#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The images firmware A of an OTA test installs (progs/ota, 32-bit):
#   t-ticker-f1: trusted, format 1
#   t-ticker-f2: trusted, format 2
#   u-ticker:    untrusted, format 2 with its shipped certificate
# and progs/ota/ota.assets with all three (otaa.toit installs u-* untrusted).
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ab8ae657bf5edfc00}
A=/home/flo/work/opentoit-sandbox-artifacts/s3-ota-soak
SRC=$A/progs/ota
OUT=$A/progs/ota/images
mkdir -p "$OUT"
TOIT=$WT/build/host/sdk/bin/toit
COMPILE=$WT/build/host/sdk/lib/toit/bin/toit.compile
image() {  # name source compile-args...
  local name=$1 src=$2
  shift 2
  (cd "$SRC" && "$COMPILE" "$@" -w "$OUT/$name.snapshot" "$SRC/$src")
  "$TOIT" tool snapshot-to-image --format=binary -m32 -o "$OUT/$name.image" "$OUT/$name.snapshot"
}
image t-ticker-f1 t-ticker.toit -Xbytecode_format=1
image t-ticker-f2 t-ticker.toit
image u-ticker u-ticker.toit --untrusted
rm -f "$SRC/ota.assets"
"$TOIT" tool assets -e "$SRC/ota.assets" create
for n in t-ticker-f1 t-ticker-f2 u-ticker; do
  "$TOIT" tool assets -e "$SRC/ota.assets" add "$n" "$OUT/$n.image"
done
ls -l "$OUT"/*.image "$SRC/ota.assets"
