#!/usr/bin/env bash
# The kept read-only data input sections of a device_size.sh link, largest
# first, from the linker map (only the part after "Linker script and memory
# map": discarded sections are listed before it). Usage: rodata.sh DIR [N]
DIR="$1"; N="${2:-40}"
awk '/^Linker script and memory map/ {on=1} on' "$DIR/size.map" \
  | awk '/^ \.s?rodata/ {name=$1; if (NF>=3) {print name, $3} else {getline; print name, $2}}' \
  | awk '{s=strtonum($2); if (s>0) print s, $1}' | sort -rn > "$DIR/rodata-sections.txt"
awk '{t+=$1} END {print "kept rodata input sections: " t " B"}' "$DIR/rodata-sections.txt"
head -"$N" "$DIR/rodata-sections.txt"
