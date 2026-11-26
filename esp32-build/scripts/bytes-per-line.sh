#!/usr/bin/env bash
# Attributes the bytes of a function in an object compiled with -g to
# source lines (objdump -d -l) and prints the lines with the most bytes,
# plus totals per 20-line block of the given source file.
# Usage: bytes-per-line.sh OBJ FUNCTION-REGEX SOURCE-BASENAME [OBJDUMP]
OBJ=$1
FN=$2
SRC=$3
OBJDUMP=${4:-xtensa-esp32-elf-objdump}
"$OBJDUMP" -d -l -C "$OBJ" | awk -v fn="$FN" -v src="$SRC" '
  /^[0-9a-f]+ <.*>:$/ { infn = ($0 ~ fn); next }
  !infn { next }
  /^\/.*:[0-9]+/ { split($0, a, ":"); file = a[1]; line = a[2] + 0; n = split(file, p, "/"); cur = p[n] ":" line; next }
  /^ *[0-9a-f]+:\t/ {
    split($0, f, "\t"); bytes = f[2]; gsub(/ /, "", bytes); sz = length(bytes) / 2;
    total += sz; per[cur] += sz;
    if (index(cur, src ":") == 1) { split(cur, q, ":"); blk = int(q[2] / 20) * 20; perblk[blk] += sz }
  }
  END {
    printf "total %d\n", total;
    for (k in per) printf "L %6d %s\n", per[k], k;
    for (b in perblk) printf "B %6d %s:%d-%d\n", perblk[b], src, b, b + 19;
  }
' | sort -k2 -rn
