#!/usr/bin/env bash
# Largest symbols of an `nm -S --size-sort` listing, in decimal, optionally
# filtered by a regex on the name. Usage: bigsyms.sh NM-FILE [COUNT] [REGEX]
set -euo pipefail
F=$1
N=${2:-40}
RE=${3:-.}
awk -v re="$RE" 'NF >= 4 && $4 ~ re { printf "%8d %s %s\n", strtonum("0x" $2), $3, $4 }' "$F" | sort -n | tail -"$N"
