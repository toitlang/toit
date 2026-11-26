#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Compares two firmware builds of bins/: the differing bytes of toit.bin
# (offsets), every allocated ELF section, and the sdkconfig.
# Usage: cmpbuild.sh TARGET-CONFIG-A TARGET-CONFIG-B
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
X=$A/bins/$1
Y=$A/bins/$2
case $1 in
  esp32-*) O=xtensa-esp32-elf-objcopy; P=$HOME/.espressif/tools/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin ;;
  *) O=riscv32-esp-elf-objcopy; P=$(ls -d "$HOME"/.espressif/tools/riscv32-esp-elf/*/riscv32-esp-elf/bin | tail -1) ;;
esac
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
echo "toit.bin sizes: $(stat -c %s "$X/toit.bin") $(stat -c %s "$Y/toit.bin")"
n=$(cmp -l "$X/toit.bin" "$Y/toit.bin" 2> /dev/null | wc -l)
echo "toit.bin differing bytes: $n"
cmp -l "$X/toit.bin" "$Y/toit.bin" 2> /dev/null | awk '{print $1 - 1}' |
  awk 'NR == 1 {s = $1; p = $1; next} $1 == p + 1 {p = $1; next} {print "  offsets " s "-" p; s = $1; p = $1} END {if (NR) print "  offsets " s "-" p}' | head -12
for s in $(awk 'NR > 2 && $1 ~ /^\./ && $3 != 0 {print $1}' "$X/sections.txt"); do
  "$P/$O" -O binary --only-section="$s" "$X/toit.elf" "$T/a" 2> /dev/null
  "$P/$O" -O binary --only-section="$s" "$Y/toit.elf" "$T/b" 2> /dev/null
  if cmp -s "$T/a" "$T/b"; then echo "section $s: same"; else echo "section $s: DIFFERS"; fi
done
echo "sections.txt diff (sizes):"
diff <(tail -n +2 "$X/sections.txt") <(tail -n +2 "$Y/sections.txt") | sed 's/^/  /'
echo "sdkconfig diff:"
diff <(grep -v "^# Espressif IoT" "$X"/*.sdkconfig) <(grep -v "^# Espressif IoT" "$Y"/*.sdkconfig) | sed 's/^/  /'
