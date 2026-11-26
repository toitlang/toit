#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Rebuilds every EC618 configuration with the current host SDK, the harnesses,
# and reruns the suites, instruction counts and installs.
set -u
S=/home/flo/work/opentoit-sandbox-artifacts/ec618/scripts
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
bash "$S/build-all.sh"
bash "$S/harness-build.sh" build/ec618 build/ec618-f2 build/ec618-f2s build/ec618-f2z build/ec618-f2cxx 2>&1 | grep '^build/'
bash "$S/suite-envelope.sh" "$WT/build/ec618/firmware.envelope" "$A/qemu/env/f1-suite.envelope" 1 > /dev/null
bash "$S/suite-envelope.sh" "$WT/build/ec618-f2/firmware.envelope" "$A/qemu/env/f2-suite.envelope" 2 > /dev/null
bash "$S/qrun.sh" "$A/qemu/run-f1-final.txt" build/ec618 "$A/qemu/env/f1-suite.envelope"
bash "$S/qrun.sh" "$A/qemu/run-f2-final.txt" build/ec618-f2 "$A/qemu/env/f2-suite.envelope"
for c in "f1 build/ec618 1" "f2 build/ec618-f2 2" "f2s build/ec618-f2s 2" "f2z build/ec618-f2z 2" "f2cxx build/ec618-f2cxx 2"; do
  read -r n b f <<< "$c"
  bash "$S/insn-bench.sh" "$n" "$b" "$f" > /dev/null || echo "$n failed"
done
bash "$S/insn-install.sh" f2 build/ec618-f2 > "$A/qemu/install-f2.txt"
bash "$S/insn-install.sh" f2s build/ec618-f2s > "$A/qemu/install-f2s.txt"
bash "$S/size-table.sh" > "$A/sizes.txt"
echo done
