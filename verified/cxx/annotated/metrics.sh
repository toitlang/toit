#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Counts, per sidecar (*.render), the lines of rendered C++ (the copies in
# the @render sections), of annotations among them (`//@`, `/*@ ... @*/`:
# contracts, invariants, ghost statements), of hand-written C in the
# verbatim sections (trusted prototypes, structs) and of annotations there
# (predicates, lemmas, the contracts of the trusted prototypes). Comments
# and blank lines are not counted. Usage: metrics.sh [SIDECAR...]

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
files=("$@")
[ ${#files[@]} -eq 0 ] && files=(model/objects.render $(ls model/*.render | grep -v '^model/objects\.render$' | sort) $(ls */*.render | grep -v '^model/' | sort))
printf '%-30s %8s %8s %8s %8s %8s\n' sidecar functions "C++" annot "C(trust)" annot
for f in "${files[@]}"; do
  awk -v name="$f" '
    BEGIN { sec = "verbatim"; fns = 0; cpp = 0; ra = 0; vc = 0; va = 0; inghost = 0; incomment = 0 }
    /^@[a-z]/ {
      split($0, w, " "); d = substr(w[1], 2)
      if (d == "render") { sec = "render"; fns++ }
      else if (d == "verbatim" || d == "verbatim-c" || d == "prototypes") sec = "verbatim"
      next
    }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      ghost = 0
      if (inghost) { ghost = 1; if (line ~ /@\*\//) inghost = 0 }
      else if (incomment) { if (line ~ /\*\//) incomment = 0; next }
      else if (line == "") next
      else if (line ~ /^\/\*@/) { ghost = 1; if (line !~ /@\*\//) inghost = 1 }
      else if (line ~ /^\/\/@/) ghost = 1
      else if (line ~ /^\/\//) next
      else if (line ~ /^\/\*/) { if (line !~ /\*\//) incomment = 1; next }
      if (sec == "render") { if (ghost) ra++; else cpp++ }
      else { if (ghost) va++; else vc++ }
    }
    END { printf "%-30s %8d %8d %8d %8d %8d\n", name, fns, cpp, ra, vc, va }
  ' "$f"
done
