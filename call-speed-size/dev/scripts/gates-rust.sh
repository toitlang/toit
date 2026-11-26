#!/usr/bin/env bash
# The device-library gates of verified/vmverify/tests: nostd, nopanic and
# the Xtensa codegen check (opt 3 and z). Logs in logs/gate-*-TAG.log.
# Usage: gates-rust.sh TAG
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc}
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
TAG=$1
cd "$WT"
for g in nostd_check nopanic_check; do
  if bash "verified/vmverify/tests/$g.sh" > "$A/logs/gate-$g-$TAG.log" 2>&1; then echo "$g: passed"; else echo "$g: FAILED"; fi
done
for opt in 3 z; do
  if bash verified/vmverify/tests/xtensa_codegen_check.sh "$opt" > "$A/logs/gate-xtensa-$opt-$TAG.log" 2>&1; then
    echo "xtensa_codegen_check ($opt): passed"
  else
    echo "xtensa_codegen_check ($opt): FAILED"
  fi
done
