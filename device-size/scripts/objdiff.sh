#!/usr/bin/env bash
# Per-object-file size difference between two firmware builds (size-files.txt
# of size.sh): "delta old new file", sorted.
# Usage: objdiff.sh BIN-DIR-A BIN-DIR-B [PATTERN]
set -euo pipefail
PAT=${3:-'\.(cc|c|cpp)\.obj$|\.o$'}
a=$(mktemp); b=$(mktemp)
awk -v p="$PAT" '$1 ~ p { s[$1] += $NF } END { for (k in s) print k, s[k] }' "$1/size-files.txt" | sort > "$a"
awk -v p="$PAT" '$1 ~ p { s[$1] += $NF } END { for (k in s) print k, s[k] }' "$2/size-files.txt" | sort > "$b"
join -a1 -a2 -e0 -o0,1.2,2.2 "$a" "$b" | awk '{ d = $3 - $2; if (d != 0) print d, $2, $3, $1 }' | sort -n
rm -f "$a" "$b"
