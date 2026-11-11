#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Counts, per annotated file, the lines of C code, of annotations (inside
# `//@` and `/*@ ... @*/`) and of comments. Usage: metrics.sh [FILE...]

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
files=("$@")
[ ${#files[@]} -eq 0 ] && files=(model/objects.h model/objects.c model/arith.gh encoder/message_encoder.c grow/grow_stack.c prims/string_write.c utf8/utf_8_to_16.c)
printf '%-28s %6s %6s %6s\n' file code annot comment
for f in "${files[@]}"; do
  awk -v name="$f" '
    BEGIN { code = 0; annot = 0; comment = 0; inghost = 0; incomment = 0 }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (inghost) { annot++; if (line ~ /@\*\//) inghost = 0; next }
      if (incomment) { comment++; if (line ~ /\*\//) incomment = 0; next }
      if (line == "") next
      if (line ~ /^\/\*@/) { annot++; if (line !~ /@\*\//) inghost = 1; next }
      if (line ~ /^\/\/@/) { annot++; next }
      if (line ~ /^\/\//) { comment++; next }
      if (line ~ /^\/\*/) { comment++; if (line !~ /\*\//) incomment = 1; next }
      code++
    }
    END { printf "%-28s %6d %6d %6d\n", name, code, annot, comment }
  ' "$f"
done
