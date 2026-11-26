#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Sizes of an EC618 slot build: sections, the populated slot, components.
# Usage: sizes.sh BUILD-DIR LOG
set -euo pipefail
BIN=/home/flo/work/opentoit-sandbox-artifacts/ec618/bin
D="$1"
LOG="$2"
echo "== $D"
"$BIN/arm-none-eabi-size" -A "$D/toit-slot-a.elf" | grep -E '^\.(vm|toit)'
grep 'ext-verify\] OK' "$LOG" | head -1 || true
grep -E 'Slot reloc table' "$LOG" | tail -1 || true
stat -c '%s %n' "$D/system.snapshot" "$D/toit.binpkg" "$D/slot-a.slotbin" "$D/slot-reloc.bin" "$D/slot-data.bin"
# Components of .vm_a by archive member (from the link map is not kept, so by
# symbol): the Rust library's symbols are those defined in it.
"$BIN/arm-none-eabi-nm" -S --size-sort -C "$D/toit-slot-a.elf" > "$D/symbols-sized.txt"
