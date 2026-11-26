#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: time-only builds (f2time) of each commit of the branch
# at three code layouts (pad 0, 2400, 6272) and their install envelopes,
# for bisecting the verification wall time. Usage: bisect-builds.sh TAG=REV...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A"
export TMPDIR=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f/build/tmp
for spec in "$@"; do
  tag=${spec%%=*}
  rev=${spec#*=}
  for pad in 0 2400 6272; do
    if [ "$pad" = 0 ]; then
      SRCREV=$rev SUFFIX=$tag bash scripts/fw-all.sh esp32 "$tag" f2time
      bash scripts/mkenv.sh esp32 "f2time-$tag" install > /dev/null 2>&1 || echo "fail env $tag"
    else
      PAD=$pad SRCREV=$rev SUFFIX=$tag bash scripts/fw-all.sh esp32 "$tag" f2time
      bash scripts/mkenv.sh esp32 "f2time-p$pad-$tag" install > /dev/null 2>&1 || echo "fail env $tag $pad"
    fi
  done
done
