#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The core (whole and split loop) at both word widths with verus.sh, and the
# escape-hatch audit (audit.sh). Usage: verus-all.sh TAG   (summary in logs/verus-all-TAG.txt)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-3
TAG=$1
OUT=$A/logs/verus-all-$TAG.txt
{
  bash "$A/scripts/verus.sh" "$TAG" 64
  bash "$A/scripts/verus.sh" "$TAG" 32
  bash "$A/scripts/verus.sh" "$TAG-split" 64 'feature="split-loop"'
  bash "$A/scripts/verus.sh" "$TAG-split" 32 'feature="split-loop"'
  bash "$A/scripts/audit.sh" "$TAG"
} > "$OUT" 2>&1
cat "$OUT"
