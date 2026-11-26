#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The layout-perturbed firmware builds of split-option, one after the other
# (fw.sh's pad edits src/vm.cc in the worktree), each followed by nothing
# else; esp32-queue.sh and c6-queue.sh run the sessions as builds appear.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/split-option
cd "$A" || exit 1
for p in 2400 6272 11104; do
  for c in f1 f2 f2s; do
    [ -f "bins/esp32-$c-p$p/sections.txt" ] || PAD=$p bash scripts/fw-all.sh esp32 so "$c"
  done
done
[ -f bins/esp32-f2sf/sections.txt ] || bash scripts/fw-all.sh esp32 so f2sf
for p in 2400 6272; do
  PAD=$p bash scripts/fw-all.sh esp32c6 so f1 f2 f2s
done
echo "queue done"
