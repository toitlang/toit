#!/usr/bin/env bash
# Exposure of the device library to the known Xtensa wrong-code bugs, by
# differential compilation: the bitcode rustc fed to codegen (bc/) is
# compiled with the stock llc (3eeb0284, the esp 1.99.0.0 LLVM) and with
# llc built from each fix branch, and the disassembly is compared function
# by function. A fix that changes no instruction of our library means the
# library does not reach the code path that fix changes. The pattern scan
# (scan-asm.sh) runs on rustc's own objects as well.
# Usage: exposure.sh <devlib-name> <opt: -O3|-O2>
set -euo pipefail
NAME=$1
OL=$2
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes
S=$ROOT/scripts
D=$ROOT/devlib/$NAME
bash "$S/llc-recompile.sh" "$NAME" "$ROOT/llvm-build-stock" stock "$OL" --trap-unreachable --no-trap-after-noreturn > /dev/null
for br in fix-139 fix-140 fix-142 fix-278-byval all-fixes; do
  bash "$S/llc-recompile.sh" "$NAME" "$ROOT/llc-bin/$br" "$br" "$OL" --trap-unreachable --no-trap-after-noreturn > /dev/null
done
{
  echo "== $NAME ($OL): rustc objects, pattern scan"
  bash "$S/scan-asm.sh" "$D/all.dis" | tail -5 || true
  echo "== llc stock recompile vs rustc objects (scheduling noise expected)"
  bash "$S/compare-recompile.sh" "$NAME" stock rustc | awk '{ split($3, x, "="); d += x[2]; split($2, y, "="); l += y[2] } END { print "lines", l, "differing", d }'
  for br in fix-139 fix-140 fix-142 fix-278-byval all-fixes; do
    echo "== stock vs $br"
    bash "$S/compare-recompile.sh" "$NAME" stock "$br" | awk '{ split($3, x, "="); d += x[2]; if (x[2] > 0) print "  " $0 } END { print "  total differing lines", d }'
  done
} | tee "$D/exposure.txt"
