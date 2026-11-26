#!/usr/bin/env bash
# Compiles the two larger host programs (run-image, toit.run: 54-65 KB of
# bytecodes) in format 2 into images/ for verify-ir.sh.
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build
cd "$WT"
for p in run-image toit.run; do
  "$WT/build/host/sdk/lib/toit/bin/toit.compile" -Xbytecode_format=2 --project-root "$WT/system/extensions/host" \
    -w "$A/images/$p.snapshot" "$WT/system/extensions/host/$p.toit" || echo "$p failed"
done
ls -la "$A/images/"*.snapshot
