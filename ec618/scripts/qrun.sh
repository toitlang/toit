#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Runs an envelope on a harness build under the user-local QEMU.
# Usage: qrun.sh OUT-FILE BUILD-DIR ENVELOPE [QEMU-ARGS...]
set -u
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
OUT=$1
B=$2
ENV=$3
shift 3
cd "$WT"
start=$(date +%s)
QEMU=$A/qemu/install/bin/qemu-system-arm TIMEOUT=${TIMEOUT:-1800} \
  tests/ec618-qemu/run.sh "$B/tests/ec618-qemu/${HARNESS:-toit_ec618_qemu}.elf" "$ENV" "$@" > "$OUT" 2>&1
code=$?
echo "[qrun] exit $code, $(( $(date +%s) - start )) s host time" >> "$OUT"
echo "exit $code"
