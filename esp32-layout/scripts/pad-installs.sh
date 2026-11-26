#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: untrusted installs (hwinstall, WiFi) of the f2time builds of
# one suffix at the given pads, two at a time on the two rig boards; waits
# for each build. Prints the install table at the end.
# Usage: pad-installs.sh SUFFIX [PADS: default "0 2400 6272 11104"] [CONFIG: default f2time]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
SUF=$1
read -r -a PADS <<< "${2:-0 2400 6272 11104}"
C=${3:-f2time}
cd "$A" || exit 1
names=()
one() {  # board name
  until [ -f "bins/esp32-$2/sections.txt" ]; do sleep 15; done
  [ -f "env/esp32-$2-install.envelope" ] || bash scripts/mkenvs.sh esp32 "$2" install > /dev/null
  bash scripts/hwrun.sh "$1" "esp32-$2-install" "$1-$2-install" 900 --test-partitions --wifi > /dev/null 2>&1
}
i=0
while [ $i -lt ${#PADS[@]} ]; do
  pids=()
  for b in b1 b2; do
    [ $i -lt ${#PADS[@]} ] || break
    p=${PADS[$i]}; n=$C; [ "$p" != 0 ] && n=$C-p$p; n=$n-$SUF
    one $b "$n" & pids+=($!)
    names+=("$b-$n-install")
    i=$((i + 1))
  done
  wait "${pids[@]}"
done
bash scripts/install-table.sh "${names[@]}" | grep -E "==|a-hello|c-map|g-big"
