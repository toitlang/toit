#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Runs several hwrun.sh invocations on one board in sequence.
# Usage: hwseq.sh BOARD TAG KIND[:flash-options,...] ...
#   For each KIND: env <target>-<config>-<kind>, log <board>-<config>-<kind><TAG>.
#   CONFIG and TARGET come from the environment (CONFIG, TARGET).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/split-option
BOARD=$1
TAG=$2
shift 2
for spec in "$@"; do
  kind=${spec%%:*}
  opts=()
  if [ "$spec" != "$kind" ]; then
    IFS=, read -r -a opts <<< "${spec#*:}"
  fi
  echo "== $BOARD $TARGET-$CONFIG-$kind ${opts[*]}"
  bash "$A/scripts/hwrun.sh" "$BOARD" "$TARGET-$CONFIG-$kind" "$BOARD-$CONFIG-$kind$TAG" 600 "${opts[@]}" | tail -60
done
