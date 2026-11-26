#!/usr/bin/env bash
# Recompiles the bitcode rustc fed to codegen (build-devlib.sh, bc/) with
# an llc (stock or patched) and disassembles it, so that the output can be
# compared with rustc's own objects and with other llc builds.
# The options mirror rustc's TargetMachine for xtensa-esp32-none-elf:
# cpu esp32, static relocation, function and data sections. The opt level
# is the module's (-O3 for opt-level 3, -O2 for s/z: rustc maps s/z to
# CodeGenOptLevel::Default; the function attributes carry optsize/minsize).
#
# Usage: llc-recompile.sh <devlib-name> <llc-build-dir> <out-name> [-O3|-O2] [extra llc args]
set -euo pipefail
NAME=$1
LLC_DIR=$2
TAG=$3
OL=${4:--O3}
shift 4 || shift $#
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes
export PATH="$HOME/.rustup/toolchains/esp/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin:$PATH"
OUT=$ROOT/devlib/$NAME/recompile-$TAG
rm -rf "$OUT"
mkdir -p "$OUT"
for f in "$ROOT/devlib/$NAME"/bc/*.bc; do
  b=$(basename "$f" .bc)
  [ -f "$ROOT/devlib/$NAME/obj/$b.o" ] || continue
  ol=$OL
  # toit_spec is built at opt-level z (profile override): codegen -O2.
  case $b in toit_spec-*) ol=-O2 ;; esac
  "$LLC_DIR/bin/llc" "$ol" -mcpu=esp32 -relocation-model=static -function-sections -data-sections \
    "$@" -filetype=obj "$f" -o "$OUT/$b.o"
  xtensa-esp32-elf-objdump -d --no-show-raw-insn "$OUT/$b.o" | tail -n +4 > "$OUT/$b.dis"
done
ls "$OUT" | wc -l
