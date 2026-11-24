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

# The primitives of the untrusted set (CONTRACTS.toml [prim_retry]) whose C++
# body has a VeriFast proof (a rendered, not contract-only, definition of
# primitive_NAME), split by whether the core has a Rust port
# (verified/core/src/prims/mod.rs `family`: the C++ then runs when the port
# declines). Printed for the whole matrix (no SIDECAR given).
if [ $# -eq 0 ]; then
  untrusted=$(awk '/^\[prim_retry\]/ { on = 1; next } /^\[/ { on = 0 } on && !/^ *#/' ../../CONTRACTS.toml \
    | grep -o '"\(core\|bitmap\|timer\|events\)\.[a-z0-9_]*"' | sed 's/"[a-z]*\.\([a-z0-9_]*\)"/\1/' | sort -u)
  ported=$(sed -n '/pub fn family/,/^}/p' ../../core/src/prims/mod.rs | grep -o 'ix::[A-Z0-9_]*' | sed 's/ix:://' | tr 'A-Z' 'a-z' | sort -u)
  proved=$(cat */*.gen.c | grep -A1 '^Object \*primitive_[a-z0-9_]*(Process \*process, Object \*\*__args)$' \
    | grep -B1 '^/\*@\|^//@' | grep -o 'primitive_[a-z0-9_]*' | sed 's/^primitive_//' | sort -u)
  count() { if [ -z "$1" ]; then echo 0; else echo "$1" | wc -l; fi; }
  in_set=$(comm -12 <(echo "$untrusted") <(echo "$proved"))
  n_untrusted=$(count "$untrusted")
  n_ported=$(count "$(comm -12 <(echo "$untrusted") <(echo "$ported"))")
  n_ported_proved=$(count "$(comm -12 <(echo "$in_set") <(echo "$ported"))")
  n_cxx_proved=$(count "$(comm -23 <(echo "$in_set") <(echo "$ported"))")
  echo
  echo "untrusted primitives: $n_untrusted; with a Rust port: $n_ported (C++ body VeriFast-proved: $n_ported_proved," \
    "contract-only: $((n_ported - n_ported_proved))); C++ only: $((n_untrusted - n_ported)) (VeriFast-proved: $n_cxx_proved)"
fi
