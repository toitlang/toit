#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-final: which entries of the pinned hot-flash list
# (toolchains/idf/components/toit/hot_flash_functions.txt) matched an input
# section of the build's .flash.toit_hot output section (toit.map), and
# which matched nothing (renamed, removed, inlined or placed in IRAM).
# Usage: hot-check.sh BUILD-DIR FORMAT   (bins/esp32-<config>, FORMAT 1 or 2)
# Prints "MISS <entry> <size note>" per unmatched entry and a summary.
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f
LIST=${LIST:-$WT/toolchains/idf/components/toit/hot_flash_functions.txt}
D=$1
F=$2
MAP=$D/toit.map
TMP=$(mktemp -d "$WT/build/tmp/hotcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# Input section names (.text.* only) inside .flash.toit_hot, and all .text
# input section names of the whole map (to tell "elsewhere" from "gone").
awk '
  /^\.flash\.toit_hot/ { inhot = 1; next }
  /^\.flash\.text/ { inhot = 0 }
  /^ \.text\./ { n = $1; if (inhot) print n > "'"$TMP"'/hot"; print n > "'"$TMP"'/all" }
' "$MAP"
sort -u -o "$TMP/hot" "$TMP/hot"
sort -u -o "$TMP/all" "$TMP/all"
total=0; hit=0; miss=0; missb=0; elsewhere=0
while IFS= read -r raw; do
  line=${raw%%#*}
  note=""
  [[ "$raw" == *"#"* ]] && note=${raw#*#}
  line=$(printf '%s' "$line" | tr -d ' \t')
  [ -z "$line" ] && continue
  case $line in
    f1:*) [ "$F" = 1 ] || continue; line=${line#f1:} ;;
    f2:*) [ "$F" = 2 ] || continue; line=${line#f2:} ;;
  esac
  total=$((total + 1))
  found=0
  while IFS= read -r s; do
    name=${s#.text.}
    # The linker patterns: .text.F, .text.F.*, .text.F$*.
    case $name in
      $line|$line.*|$line\$*) found=1; break ;;
    esac
  done < "$TMP/hot"
  if [ $found = 1 ]; then
    hit=$((hit + 1))
  else
    miss=$((miss + 1))
    b=$(printf '%s' "$note" | sed -n 's/^ *\([0-9]*\) B.*/\1/p')
    missb=$((missb + ${b:-0}))
    where=gone
    while IFS= read -r s; do
      name=${s#.text.}
      case $name in
        $line|$line.*|$line\$*) where=elsewhere; break ;;
      esac
    done < "$TMP/all"
    [ $where = elsewhere ] && elsewhere=$((elsewhere + 1))
    echo "MISS ($where) $line #$note"
  fi
done < "$LIST"
echo "SUMMARY format $F: $total entries, $hit matched, $miss unmatched ($elsewhere of them still linked elsewhere), unmatched list size $missb B"
