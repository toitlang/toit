#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: bench + perf sessions of f1 and f2 builds of one suffix at
# the four pads (0, 2400, 6272, 11104), each pair in parallel on the two
# rig boards, the boards alternating between pads (f1 on b1 / f2 on b2 for
# pads 0 and 6272... swapped for 2400 and 11104). Waits for each build.
# Usage: pad-sessions.sh SUFFIX [RUN] [CONFIGS: default "f1 f2"]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
SUF=$1
RUN=${2:-r1}
read -r -a CFG <<< "${3:-f1 f2}"
cd "$A" || exit 1
w() { until [ -f "bins/esp32-$1/sections.txt" ]; do sleep 15; done; }
i=0
for p in "" -p2400 -p6272 -p11104; do
  b1=b1; b2=b2
  [ $((i % 2)) = 1 ] && { b1=b2; b2=b1; }
  i=$((i + 1))
  pids=()
  if [ ${#CFG[@]} = 2 ]; then
    w "${CFG[0]}$p-$SUF"; w "${CFG[1]}$p-$SUF"
    bash scripts/session.sh $b1 esp32 "$RUN" "${CFG[0]}$p-$SUF" & pids+=($!)
    bash scripts/session.sh $b2 esp32 "$RUN" "${CFG[1]}$p-$SUF" & pids+=($!)
  else
    w "${CFG[0]}$p-$SUF"
    bash scripts/session.sh $b2 esp32 "$RUN" "${CFG[0]}$p-$SUF" & pids+=($!)
  fi
  wait "${pids[@]}"
done
echo "pad sessions $SUF done"
