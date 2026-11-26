#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds the device staticlib of the worktree for riscv32imac (the C6's
# cargo command of the firmware build, opt-level 3) into build/rv-asm and
# prints the size of the named functions; with -d, their disassembly.
# Usage: rvasm.sh [-d] PATTERN...   (PATTERN: a demangled-name regex)
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a063f79f8b4a649b9}
T=$HOME/.espressif/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin
DIS=0
if [ "${1:-}" = -d ]; then DIS=1; shift; fi
export TMPDIR=$WT/build/tmp
cd "$WT/verified/vmverify/staticlib" || exit 1
CARGO_PROFILE_DEVICE_OPT_LEVEL=3 cargo build --profile device --quiet --lib \
  --manifest-path "$WT/verified/vmverify/staticlib/Cargo.toml" \
  --target-dir "$WT/build/rv-asm" --target riscv32imac-unknown-none-elf \
  --no-default-features --features device-runtime || exit 1
LIB=$(ls "$WT"/build/rv-asm/riscv32imac-unknown-none-elf/device/libtoit_rust.a)
for p in "$@"; do
  "$T/riscv32-esp-elf-nm" -S -C --size-sort "$LIB" 2>/dev/null | grep -E "$p" | awk '{printf "%6d %s\n", strtonum("0x" $2), substr($0, index($0, $4))}'
  if [ $DIS = 1 ]; then
    "$T/riscv32-esp-elf-objdump" -d --no-show-raw-insn -C "$LIB" 2>/dev/null |
      awk -v re="$p" '/^[0-9a-f]+ <.*>:$/ { on = ($0 ~ re) } on'
  fi
done
