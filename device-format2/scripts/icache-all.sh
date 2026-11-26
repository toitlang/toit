#!/usr/bin/env bash
# Runs the instruction-cache estimate (icache-sim.sh) for the given esp32
# configurations with the icache.toit workload once and twice; the
# difference is one run of richards, deltablue and pystone.
# Usage: icache-all.sh TAG [CONFIGS...]   (results in qemu/icache-<config>-<rounds>.txt)
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a5fbf012570cfb044}
A=/home/flo/work/opentoit-sandbox-artifacts/device-format2
TOIT=$WT/build/host/sdk/bin/toit
TAG=$1
shift
CONFIGS=${*:-f1 f2}
pids=()
for c in $CONFIGS; do
  format=2
  [ "$c" = f1 ] && format=1
  for r in 1 2; do
    d=$A/qemu/icache-src-$c-$r
    rm -rf "$d"
    mkdir -p "$d"
    cp "$A"/qemu/progs/{icache,richards,deltablue,pystone,benchmark}.toit "$d/"
    echo "ROUNDS ::= $r" > "$d/rounds.toit"
    TOIT_BYTECODE_FORMAT=$format "$TOIT" compile --snapshot -o "$d/icache.snapshot" "$d/icache.toit" || exit 1
    cp "$A/bins/esp32-$c/firmware.envelope" "$d/fw.envelope"
    "$TOIT" tool firmware -e "$d/fw.envelope" container install icache "$d/icache.snapshot" || exit 1
    bash "$A/scripts/icache-sim.sh" "$d/fw.envelope" "$A/qemu/icache-$c-$r-$TAG.txt" 3600 > /dev/null 2>&1 &
    pids+=($!)
  done
done
for p in "${pids[@]}"; do wait "$p"; done
for c in $CONFIGS; do
  for r in 1 2; do
    echo "== $c rounds $r"
    cat "$A/qemu/icache-$c-$r-$TAG.txt"
    grep -a "ICACHE" "$A/qemu/icache-$c-$r-$TAG.txt.serial"
  done
done
