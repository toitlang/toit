#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Compiles Jaguar (format 2, -O2) with the worktree's SDK and prints the
# -m32 image sizes of Jaguar and of the system snapshot of bins/esp32-CONFIG,
# and the bytecode padding (RETURN_NULL pads, format note 21) of both.
# Usage: images.sh CONFIG
set -euo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc}
TOIT=$WT/build/host/sdk/bin/toit
C=$1
cd "$A"
TOIT_BYTECODE_FORMAT=2 "$TOIT" compile -O2 --snapshot --project-root /home/flo/work/jaguar -o jaguar/jaguar-f2.snapshot /home/flo/work/jaguar/src/jaguar.toit
"$TOIT" tool snapshot-to-image -m32 --format=binary -o jaguar/jaguar-f2.image jaguar/jaguar-f2.snapshot
"$TOIT" tool snapshot-to-image -m32 --format=binary -o "bins/esp32-$C/system.image32" "bins/esp32-$C/system.snapshot"
echo "jaguar image $(stat -c %s jaguar/jaguar-f2.image)  system image $(stat -c %s "bins/esp32-$C/system.image32")"
