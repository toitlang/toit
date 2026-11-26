#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Counts the ELF relocation types of every object in a static library.
# Usage: relocs.sh LIB.a
set -euo pipefail
BIN=/home/flo/work/opentoit-sandbox-artifacts/ec618/bin
LIB="$(realpath "$1")"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
cd "$W"
"$BIN/arm-none-eabi-ar" x "$LIB"
for f in *.o; do "$BIN/arm-none-eabi-readelf" -rW "$f"; done | awk '$3 ~ /^R_ARM/ {print $3}' | sort | uniq -c
