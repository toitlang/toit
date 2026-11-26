#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: verification time (median (min-max), s) of a-hello, c-map
# and g-big per configuration and pad, from the f2time install logs.
# Usage: install-pads-table.sh   (configurations below)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
S=$A/scripts
row() {
  local label=$1; shift
  for prog in a-hello c-map g-big; do
    printf "| %s | %s |" "$label" "$prog"
    for L in "$@"; do
      v=$(bash "$S/install-table.sh" "$L" | awk -v p=$prog '$1 == p {print $4, $5}')
      printf " %s |" "$v"
    done
    echo
  done
}
echo "| build | program | pad 0 | pad 2400 | pad 6272 | pad 11104 |"
echo "|---|---|---:|---:|---:|---:|"
row "base" b2-f2time-base-install b1-f2time-p2400-base-install b2-f2time-p6272-base-install b2-f2time-p11104-base-install
row "v1 (loop + 26 callees)" b1-f2time-pin1-install b2-f2time-p2400-pin1-install b2-f2time-p6272-pin1-install b1-f2time-p11104-pin1-install
row "v2 (whole verifier; old IRAM list)" b1-f2time-pin2-install b2-f2time-p2400-pin2-install b1-f2time-p6272-pin2-install b2-f2time-p11104-pin2-install
row "**final** (v3, ir4)" b1-f2time-fin3-install b2-f2time-p2400-fin3-install b1-f2time-p6272-fin3-install b2-f2time-p11104-fin3-install
row "final + verifier at 0x400d4000 (dropped)" b1-f2time-fin4-install b2-f2time-p2400-fin4-install b1-f2time-p6272-fin4-install b2-f2time-p11104-fin4-install
