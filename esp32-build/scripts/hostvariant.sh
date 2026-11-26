#!/usr/bin/env bash
# Rebuilds the host toit.run of the worktree, saves it as bins/toit.run.LABEL
# and measures the interpreter instructions (ir.sh) in the given format.
# Usage: hostvariant.sh LABEL [f1|f2]
set -e
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build
export IGNORE_SUBMODULE=1 IDF_PATH=$WT/third_party/esp-idf CCACHE_BASEDIR=$WT CCACHE_NOHASHDIR=1
ninja -C "$WT/build/host" sdk/lib/toit/bin/toit.run > "$A/bins/build.$1.log" 2>&1 || { tail -20 "$A/bins/build.$1.log"; exit 1; }
cp "$WT/build/host/sdk/lib/toit/bin/toit.run" "$A/bins/toit.run.$1"
bash "$A/scripts/ir.sh" "$1" "$A/bins/toit.run.$1" "${2:-f1}"
