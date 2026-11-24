#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# The EC618 instruction-level SMT models (heap/ec618_*.smt2): Z3 on each
# file must give exactly the verdicts listed below, one per (check-sat), in
# order ("unsat": the obligation holds; "sat": a reachability check, the
# path the obligations are about can be taken). Z3 is the one of Frama-C's
# opam switch (verified/cxx/install-tools.sh framac).
#
# These models are transcriptions of Thumb code of the EC618 base firmware
# and the VM slots. What is checked here is the model; that the model is
# the code of a given linked image is not checked (the image is not in the
# repository; see verified/core/TRUSTED.md, "EC618").
#
# Usage: smt-models.sh NAME
#          checks heap/NAME.smt2 (NAME without the extension);
#        smt-models.sh --mutant LABEL NAME FROM TO
#          a self-test: in a copy of heap/NAME.smt2 with the text FROM
#          replaced by TO (verified/tools/text_replace.toit), the verdicts
#          must differ from the listed ones.
# Prints one ok or FAIL line; the exit status is the failure count.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"

declare -A VERDICTS=(
  [ec618_arena_return]="unsat unsat unsat unsat unsat"
  [ec618_chunk_admission]="unsat unsat unsat"
  [ec618_chunk_append]="unsat unsat unsat unsat"
  [ec618_external_extent]="unsat unsat unsat unsat"
  [ec618_free_buckets]="unsat unsat"
  [ec618_memmove]="unsat unsat unsat unsat"
  [ec618_memset]="unsat unsat unsat unsat"
  [ec618_object_extent]="unsat unsat unsat unsat unsat unsat unsat unsat unsat unsat"
  [ec618_object_roots]="unsat unsat unsat unsat unsat unsat unsat unsat unsat"
  [ec618_page_classify]="unsat unsat unsat"
  [ec618_process_roots]="unsat unsat unsat unsat unsat unsat unsat unsat"
  [ec618_remembered_scan]="unsat unsat unsat unsat unsat unsat unsat unsat unsat unsat unsat"
  [ec618_scavenge_capacity]="unsat unsat unsat"
  [ec618_scavenge_copy]="unsat unsat unsat unsat unsat unsat unsat unsat unsat unsat"
  [ec618_scheduler_resume]="unsat unsat unsat unsat"
  [ec618_small_grant]="unsat unsat unsat unsat sat sat"
  [ec618_small_release]="sat sat sat sat unsat unsat"
  [ec618_survivor_watermark]="unsat"
)

if [ "${1:-}" = --list ]; then
  printf '%s\n' "${!VERDICTS[@]}" | sort
  exit 0
fi

mutant=""
if [ "${1:-}" = --mutant ]; then
  [ $# -eq 5 ] || { echo "usage: smt-models.sh --mutant LABEL NAME FROM TO" >&2; exit 2; }
  mutant="$2"
  shift 2
fi
name="$1"
expected="${VERDICTS[$name]:-}"
file="$ANNOTATED_DIR/heap/$name.smt2"
label="ec618-smt/${name#ec618_}"
[ -n "$mutant" ] && label="ec618-smt-mutant/$mutant"
if [ -z "$expected" ] || [ ! -f "$file" ]; then
  printf 'FAIL  %-40s no verdicts listed for %s or no file %s\n' "$label" "$name" "$file"
  exit 1
fi
z3="$CXXV_HOME/tools/opam/root/cxxv/bin/z3"
if [ ! -x "$z3" ]; then
  printf 'FAIL  %-40s Z3 is not installed at %s (verified/cxx/install-tools.sh framac)\n' "$label" "$z3"
  exit 1
fi
log="$ACXX_WORK/logs/${label//\//-}.log"
: > "$log"
if [ -n "$mutant" ]; then
  work=$(mktemp -d "$ACXX_WORK/smt-mutant.XXXXXXXX")
  trap 'rm -rf "$work"' EXIT
  cp "$file" "$work/$name.smt2"
  file="$work/$name.smt2"
  if ! acxx_toit run "$REPO_ROOT/verified/tools/text_replace.toit" -- "$file" "$2" "$3" > "$log" 2>&1; then
    printf 'FAIL  %-40s the mutation does not apply, see %s\n' "$label" "$log"
    exit 1
  fi
fi
start=$(date +%s)
got=$(timeout 900 "$z3" "$file" 2>> "$log")
status=$?
secs=$(($(date +%s) - start))
printf '%s\n' "$got" >> "$log"
want=$(printf '%s\n' $expected)
if [ -z "$mutant" ]; then
  if [ $status -eq 0 ] && [ "$got" = "$want" ]; then
    printf 'ok    %-40s %d queries with their verdicts (%d s)\n' "$label" "$(wc -w <<< "$expected")" "$secs"
    exit 0
  fi
  printf 'FAIL  %-40s Z3 exit %d, verdicts %s, expected %s, see %s\n' "$label" $status "$(echo $got)" "$expected" "$log"
  exit 1
fi
# A mutant passes when Z3 completes and some verdict differs. An error or a
# timeout does not count: the self-test must show a wrong verdict, not a
# broken file or a slow one.
if [ $status -eq 0 ] && [ "$got" != "$want" ]; then
  printf 'ok    %-40s fails as it should: verdicts %s (%d s)\n' "$label" "$(echo $got)" "$secs"
  exit 0
fi
printf 'FAIL  %-40s the mutant %s, see %s\n' "$label" \
  "$([ $status -eq 0 ] && echo "has the expected verdicts" || echo "gave no verdicts (Z3 exit $status)")" "$log"
exit 1
