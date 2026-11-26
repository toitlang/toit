#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: the final firmwares (head d15d4415) and their envelopes.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A"
export TMPDIR=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f/build/tmp
SRCREV=d15d44155 SUFFIX=fin3 bash scripts/fw-all.sh esp32 fin3 f2 f2time f2trace
for e in "f2-fin3 soakd2" "f2-fin3 soakd" "f2time-fin3 install" "f2trace-fin3 install" "f2-fin3 bench" "f2-fin3 perf" "f2-fin3 memprobe"; do
  # shellcheck disable=SC2086
  bash scripts/mkenv.sh esp32 $e > /dev/null 2>&1 || echo "fail $e"
done
ls env | grep fin3
