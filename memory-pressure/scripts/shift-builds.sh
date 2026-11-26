#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: time-only builds (f2time) of commits with the pinned
# verifier group (hot flash list, group B) shifted by PAD bytes of dead code
# pinned right before it, and their install envelopes.
# Usage: shift-builds.sh "PAD..." TAG=REV...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A"
export TMPDIR=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f/build/tmp
pads=$1
shift
for spec in "$@"; do
  tag=${spec%%=*}
  rev=${spec#*=}
  for pad in $pads; do
    PATCH=$A/patches/hot-pad-before-verifier.patch PADMODE=own PAD=$pad SRCREV=$rev SUFFIX=$tag \
      bash scripts/fw-all.sh esp32 "$tag" f2time
    bash scripts/mkenv.sh esp32 "f2time-p$pad-$tag" install > /dev/null 2>&1 || echo "fail env $tag $pad"
  done
done
