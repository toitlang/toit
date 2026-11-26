#!/usr/bin/env bash
# Compares the disassembly of rustc's objects (devlib/<name>/obj) with an
# llc recompile (devlib/<name>/recompile-<tag>), or two recompiles.
# Prints, per object: lines, and the number of differing diff lines.
# Usage: compare-recompile.sh <devlib-name> <tag-a> [<tag-b>|rustc]
set -euo pipefail
NAME=$1
A=$2
B=${3:-rustc}
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes
D=$ROOT/devlib/$NAME
export PATH="$HOME/.rustup/toolchains/esp/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin:$PATH"
for f in "$D/recompile-$A"/*.dis; do
  b=$(basename "$f" .dis)
  if [ "$B" = rustc ]; then
    o=$D/obj/$b.o
    [ -f "$o" ] || { echo "$b: no rustc object"; continue; }
    other=$D/recompile-$A/$b.rustc-dis
    xtensa-esp32-elf-objdump -d --no-show-raw-insn "$o" | tail -n +4 > "$other"
  else
    other=$D/recompile-$B/$b.dis
  fi
  n=$(diff "$f" "$other" | grep -c '^[<>]' || true)
  echo "$b lines=$(wc -l < "$f") differing=$n"
done
