#!/usr/bin/env bash
# Progress of the running measurements (last lines of the QEMU runs).
# Usage: status.sh [TAG]
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
TAG=${1:-2}
for c in f1 f2cxx f2; do
  f=$A/qemu/run-$c-$TAG/serial.log
  [ -f "$f" ] || continue
  echo "== $c: $(grep -a -E '^(SUITE|MEM)' "$f" | tr -d '\r' | tail -1)"
done
for d in "$A"/qemu/installer-*/run; do
  [ -f "$d/serial.log" ] || continue
  echo "== $d: $(grep -a -E '^(SUITE|MEM)' "$d/serial.log" | tr -d '\r' | tail -1)"
done
for f in "$A"/qemu/icache-*.txt; do
  [ -s "$f" ] && echo "== $f: $(tr '\n' ' ' < "$f")"
done
