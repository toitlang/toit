#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# measure-3's firmware builds, one after the other (fw.sh builds from one
# copy of the worktree, build/fwsrc). STAGE=1: the plain builds; STAGE=2:
# the layout-shifted ones (PAD, fw.sh's VM::VM() pad).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
cd "$A" || exit 1
have() { [ -f "bins/$1/sections.txt" ]; }
if [ "${STAGE:-1}" = 1 ]; then
  for c in f2 f1 f2time; do have esp32-$c || bash scripts/fw-all.sh esp32 m3 $c; done
  for c in f2 f1 f2time; do have esp32c6-$c || bash scripts/fw-all.sh esp32c6 m3 $c; done
  for c in f1prev f2prev; do have esp32-$c || bash scripts/fw-all.sh esp32 m3 $c; done
  for c in f1prev f2prev; do have esp32c6-$c || bash scripts/fw-all.sh esp32c6 m3 $c; done
fi
if [ "${STAGE:-1}" = 2 ]; then
  for p in 2400 6272 11104; do
    for c in f1 f2; do have esp32-$c-p$p || PAD=$p bash scripts/fw-all.sh esp32 m3 $c; done
  done
  for p in 2400 6272; do
    for c in f1 f2; do have esp32c6-$c-p$p || PAD=$p bash scripts/fw-all.sh esp32c6 m3 $c; done
  done
fi
echo "queue stage ${STAGE:-1} done"
