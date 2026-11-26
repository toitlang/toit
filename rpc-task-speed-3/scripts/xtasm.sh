#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds the device staticlib for the classic ESP32 (xtensa-esp32-none-elf,
# esp toolchain, opt-level s: the firmware build's settings) from the
# verified/ directory VDIR into build/xt-asm-TAG and prints the sizes of
# the functions matching PATTERN.
# Usage: xtasm.sh VDIR TAG PATTERN
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a063f79f8b4a649b9}
VDIR=$1
TAG=$2
PAT=$3
NM=$HOME/.espressif/tools/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
export TMPDIR=$WT/build/tmp
cd "$VDIR/vmverify/staticlib" || exit 1
CARGO_PROFILE_DEVICE_OPT_LEVEL=s cargo +esp build --profile device --quiet --lib \
  --manifest-path "$VDIR/vmverify/staticlib/Cargo.toml" \
  --target-dir "$WT/build/xt-asm-$TAG" --target xtensa-esp32-none-elf \
  --no-default-features --features device-runtime -Zbuild-std=core,alloc || exit 1
LIB=$WT/build/xt-asm-$TAG/xtensa-esp32-none-elf/device/libtoit_rust.a
"$NM" -S -C --size-sort "$LIB" 2>/dev/null | grep -E "$PAT" | awk '{printf "%6d %s\n", strtonum("0x" $2), substr($0, index($0, $4))}'
