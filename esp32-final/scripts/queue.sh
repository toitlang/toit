#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: firmware builds one after the other (fw.sh builds from one
# copy of the worktree, build/fwsrc). Each argument is
# CONFIG[:PAD[:SUFFIX]] for the classic ESP32 (TARGET=esp32c6 etc. for
# another target); builds already in bins/ are skipped. The name is
# CONFIG[-pPAD][-SUFFIX] (fw-all.sh's SUFFIX).
# Usage: queue.sh f2:0:base f2:2400:base ...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
cd "$A" || exit 1
T=${TARGET:-esp32}
# A PAD of the form rN is a data-side pad (fw.sh RPAD=N).
for spec in "$@"; do
  IFS=: read -r c p s <<< "$spec"
  [ "${p:-0}" = 0 ] && p=""
  rp=""
  case $p in r*) rp=${p#r}; p="" ;; esac
  name=$c${p:+-p$p}${rp:+-r$rp}${s:+-$s}
  [ -f "bins/$T-$name/sections.txt" ] && { echo "have $T-$name"; continue; }
  PAD=$p RPAD=$rp SUFFIX=$s bash scripts/fw-all.sh "$T" "${s:-x}" "$c"
done
echo "queue done"
