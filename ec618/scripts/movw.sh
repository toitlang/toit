#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Lists the movw/movt relocations (object, section, type, symbol) of a static library.
# Usage: movw.sh LIB.a
set -euo pipefail
BIN=/home/flo/work/opentoit-sandbox-artifacts/ec618/bin
LIB="$(realpath "$1")"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
cd "$W"
"$BIN/arm-none-eabi-ar" x "$LIB"
for f in *.o; do
  "$BIN/arm-none-eabi-readelf" -rW "$f" | awk -v o="$f" '/^Relocation section/ {s=$3} $3 ~ /MOVW|MOVT/ {print o, s, $3, $5}'
done
