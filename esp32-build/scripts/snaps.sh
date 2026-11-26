#!/usr/bin/env bash
# Compiles the three benchmarks in format 1 and format 2 into snap/.
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build
BIN=$WT/build/host/sdk/lib/toit/bin
mkdir -p "$A/snap"
for b in richards deltablue pystone; do
  "$BIN/toit.compile" -w "$A/snap/$b-f1.snap" /home/flo/work/benchmarks/toit/$b.toit || exit 1
  "$BIN/toit.compile" -Xbytecode_format=2 -w "$A/snap/$b-f2.snap" /home/flo/work/benchmarks/toit/$b.toit || exit 1
done
ls -la "$A/snap"
