#!/usr/bin/env bash
# Sums the input sections of an output section (default .iram0.text) of a
# GNU ld map file by object file (or by input section with "-s").
# Usage: iram-by-object.sh MAP [SECTION] [-s]
MAP=$1
SEC=${2:-.iram0.text}
BY=${3:-file}
awk -v sec="$SEC" -v by="$BY" '
  function add(name, file, size) { key = (by == "-s") ? name " " file : file; sizes[key] += strtonum(size) }
  $1 == sec && NF >= 2 { inside = 1; next }
  inside && /^\.[a-z]/ { inside = 0 }
  !inside { next }
  /^ \.[^ ]+ +0x[0-9a-f]+ +0x[0-9a-f]+ / { add($1, $4, $3); pending = ""; next }
  /^ \.[^ ]+$/ { pending = $1; next }
  pending != "" && /^ +0x[0-9a-f]+ +0x[0-9a-f]+ / { add(pending, $3, $2); pending = ""; next }
  END { for (f in sizes) printf "%8d %s\n", sizes[f], f }
' "$MAP" | sort -rn
