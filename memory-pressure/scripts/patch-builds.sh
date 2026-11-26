#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: time-only builds (f2time) of commits with a patch applied
# to the build copy, at several pads of the dead-code function pinned before
# the verifier group (PADMODE=own: the patch must list 0toit_layout_pad;
# "-" builds without a pad), and their install envelopes.
# Usage: patch-builds.sh "PAD..." PATCH TAG=REV...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A"
export TMPDIR=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f/build/tmp
pads=$1
patch=$2
shift 2
for spec in "$@"; do
  tag=${spec%%=*}
  rev=${spec#*=}
  for pad in $pads; do
    if [ "$pad" = - ]; then
      PATCH=$patch SRCREV=$rev SUFFIX=$tag bash scripts/fw-all.sh esp32 "$tag" f2time
      bash scripts/mkenv.sh esp32 "f2time-$tag" install > /dev/null 2>&1 || echo "fail env $tag"
    else
      PATCH=$patch PADMODE=own PAD=$pad SRCREV=$rev SUFFIX=$tag bash scripts/fw-all.sh esp32 "$tag" f2time
      bash scripts/mkenv.sh esp32 "f2time-p$pad-$tag" install > /dev/null 2>&1 || echo "fail env $tag $pad"
    fi
  done
done
