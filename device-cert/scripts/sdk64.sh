#!/usr/bin/env bash
# Rebuilds the 64-bit host SDK (make sdk) of the worktree; log in
# device-cert/build64.log. Prints errors and the exit code.
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a9365a74954333c15
cd "$WT"
source build/worktree-env.sh
make sdk > /home/flo/work/opentoit-sandbox-artifacts/device-cert/build64.log 2>&1
rc=$?
grep -E "error:|Error " /home/flo/work/opentoit-sandbox-artifacts/device-cert/build64.log | head -30
echo "EXIT $rc"
exit $rc
