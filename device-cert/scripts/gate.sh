#!/usr/bin/env bash
# The whole gate of the task: 64-bit SDK rebuild, verified/check.sh --tests,
# full ctest -j16, the 32-bit host's sandbox tests, the no_std builds.
# Logs in device-cert/gate-<step>.log; prints a summary.
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a9365a74954333c15
S=/home/flo/work/opentoit-sandbox-artifacts/device-cert/scripts
L=/home/flo/work/opentoit-sandbox-artifacts/device-cert
cd "$WT"
"$S/sdk64.sh" > "$L/gate-sdk.log" 2>&1; echo "sdk64: $(tail -1 "$L/gate-sdk.log")"
verified/check.sh --tests > "$L/gate-check.log" 2>&1; echo "check.sh --tests: exit $? ($(grep -E 'verified, ' "$L/gate-check.log" | tr '\n' ' '))"
ctest --test-dir build/host -j16 > "$L/gate-ctest.log" 2>&1
echo "ctest: $(grep -E 'tests passed' "$L/gate-ctest.log")"; grep -E '^\s+[0-9]+ - ' "$L/gate-ctest.log"
"$S/test32.sh" > "$L/gate-test32.log" 2>&1; echo "host32 sandbox: $(grep -E 'tests passed' "$L/gate-test32.log")"
grep -E '\(Failed\)|\(Timeout\)' "$L/gate-test32.log"
verified/vmverify/tests/nostd_check.sh > "$L/gate-nostd.log" 2>&1; echo "nostd_check: exit $? ($(tail -1 "$L/gate-nostd.log"))"
