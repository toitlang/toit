#!/usr/bin/env bash
# Linked input sections of a GNU ld map file whose object path matches a
# regex: "size section object" in decimal, largest last. Skips the discarded
# sections and the zero-address (non-allocated) ones.
# Usage: mapsyms.sh MAP OBJECT-REGEX
set -euo pipefail
awk -v re="$2" '
  /^Linker script and memory map/ { on = 1; next }
  !on { next }
  # A section name alone on its line, the address/size/object on the next.
  /^ [.a-zA-Z_][^ ]*$/ { pend = $1; next }
  {
    if (pend != "" && $1 ~ /^0x/ && NF >= 3) { name = pend; addr = $1; size = $2; obj = $3 }
    else if ($1 ~ /^[.]/ && $2 ~ /^0x/ && NF >= 4) { name = $1; addr = $2; size = $3; obj = $4 }
    else { pend = ""; next }
    pend = ""
    if (obj !~ re) next
    a = strtonum(addr); s = strtonum(size)
    if (a == 0 || s == 0) next
    printf "%d %s %s\n", s, name, obj
  }' "$1" | sort -n
