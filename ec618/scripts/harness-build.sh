#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Configures an EC618 build directory with the QEMU harness and builds it.
# Usage: harness-build.sh BUILD-DIR...   (relative to the worktree)
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
for B in "$@"; do
  cd "$WT/$B"
  cmake . -DTOIT_EC618_QEMU_HARNESS=ON -DEC618_BASE_ELF="$WT/build/ec618-base/base.elf" > /dev/null
  ninja toit_ec618_qemu > /dev/null
  echo "$B: $(ls -la tests/ec618-qemu/toit_ec618_qemu.elf | awk '{print $5}')"
done
