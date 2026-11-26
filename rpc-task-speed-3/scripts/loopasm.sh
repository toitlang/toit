#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The RISC-V run loop of the current worktree (rvasm.sh), normalized for
# diffing: one "mnemonic operands" line per instruction, addresses and
# branch targets replaced by L.
# Usage: loopasm.sh OUT [FUNCTION-REGEX]
set -uo pipefail
OUT=$1
RE=${2:-step::run_loop}
bash "$(dirname "$0")/rvasm.sh" -d "$RE" 2>/dev/null |
  awk -F'\t' 'NF >= 2 && $1 ~ /^ *[0-9a-f]+:$/ { ins = $2; args = $3; gsub(/[0-9a-f]+ <[^>]*>/, "L", args); gsub(/# .*/, "", args); print ins, args }' > "$OUT"
wc -l < "$OUT"
