#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds the classic ESP32 firmwares (format 2 and format 1) of the
# fix/floor-complete head and of its base f31c45af (never flashes).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/floor-complete
export TMPDIR=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ab454ccc745a56d0b/build/tmp
SUFFIX=head bash "$A/scripts/fw-all.sh" esp32 fc ${HEAD_CONFIGS:-f2 f1}
if [ "${BASE:-1}" = 1 ]; then
  SUFFIX=base SRCREV=f31c45af bash "$A/scripts/fw-all.sh" esp32 fc f2 f1
fi
