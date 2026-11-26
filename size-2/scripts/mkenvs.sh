#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Usage: mkenvs.sh TARGET CONFIG [KINDS...]  (default: suite bench install spin)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/size-2
TARGET=$1
C=$2
shift 2
for k in ${*:-suite bench install spin}; do
  log=$A/logs/mkenv-$TARGET-$C-$k.log
  if bash "$A/scripts/mkenv.sh" "$TARGET" "$C" "$k" > "$log" 2>&1; then
    echo "ok $TARGET-$C-$k"
  else
    echo "FAILED $TARGET-$C-$k"; tail -5 "$log"
  fi
done
