#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# A reverted-bug self-test: applies a source change (e.g. a past fix taken
# out again) to a copy of the repository and to a copy of the sidecar
# alike, renders that copy and runs VeriFast on it. The proof must then
# fail, with the expected error.
#
# Usage: mutant.sh NAME SIDECAR SOURCE PATTERN "VERIFAST OPTIONS" FROM TO [FROM TO]...
#   SIDECAR relative to this directory, SOURCE relative to the repository:
#   a .cc file or a header of src/ (the copy replaces the link to the
#   original in the mutant's src/, which is first on the include path and
#   the directory of every translation unit's quoted includes; the
#   self-test decoder-uint8-bound mutates src/messaging.h), or another
#   file of the repository (the translator's self-test tests/rules.cc).
#   FROM/TO: literal texts (`\n` a newline); each must occur exactly once in
#   SOURCE and, if it occurs there at all, once in the sidecar. PATTERN
#   DRIFT: the change is applied to the source only, and the rendering must
#   fail with a drift error (the correspondence check's self-test). PATTERN
#   PASS: the mutant must verify (e.g. the reverted fix under an assumption
#   that excludes the bug). PATTERN `LP64:REGEX` or `ILP32:REGEX`: the
#   proof must fail with REGEX for that target only and verify for the
#   other (a check that is dead on one width). PATTERN `RENDER:REGEX`: the
#   rendering must fail with REGEX (a rule's check, e.g. the closure
#   rules').
# Prints one line `ok` / `FAIL` like run.sh; exit status 0 when the proof
# failed with PATTERN on both LP64 and ILP32 (or as a target prefix says).

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
name="$1"; sidecar="$2"; source="$3"; pattern="$4"; vfopts="$5"; shift 5
TOIT_BIN="${TOIT:-$REPO_ROOT/build/host/sdk/bin/toit}"
[ -x "$TOIT_BIN" ] || TOIT_BIN="$(command -v toit)"

M="$ACXX_WORK/mutants/$name"
rm -rf "$M"
mkdir -p "$M/repo/src" "$M/scratch" "$M/gen32"
# The mutant's tree goes when its verdict is out: its Clang AST dumps
# (scratch/: the JSON AST of every translation unit the sidecar renders
# from, for both targets, made anew from the changed tree; 90-550 MB) add
# up to over 70 GB for the whole matrix. Its logs stay in
# $ACXX_WORK/logs/mutants/NAME/; RUN_KEEP_MUTANTS=1 keeps the tree.
cleanup_mutant() {
  local keep="$ACXX_WORK/logs/mutants/$name" f
  mkdir -p "$keep"
  for f in "$M"/*.log; do
    [ -f "$f" ] && cp "$f" "$keep/"
  done
  [ "${RUN_KEEP_MUTANTS:-0}" = 1 ] || rm -rf "$M"
}
trap cleanup_mutant EXIT
for e in "$REPO_ROOT"/*; do
  [ "$(basename "$e")" = src ] || ln -s "$e" "$M/repo/$(basename "$e")"
done
# Keep the directory hierarchy real. A nested header can use ../../objects.h;
# following a directory symlink there would include the original header as
# well as the mutant and defeat #pragma once.
cp -Rs "$REPO_ROOT/src/." "$M/repo/src/" || exit 1
# The changed file is a copy; the directories on its path become real
# directories of links (for a source outside src/: writing through the
# links would change the checkout).
materialize() {
  local cur="$M/repo" part target e parts
  IFS=/ read -ra parts <<< "$(dirname "$1")"
  for part in "${parts[@]}"; do
    if [ -L "$cur/$part" ]; then
      target="$(readlink -f "$cur/$part")"
      rm "$cur/$part"
      mkdir "$cur/$part"
      for e in "$target"/*; do ln -s "$e" "$cur/$part/$(basename "$e")"; done
    fi
    cur="$cur/$part"
  done
  rm -f "$cur/$(basename "$1")"
}
materialize "$source"
cp "$REPO_ROOT/$source" "$M/repo/$source"
mkdir -p "$M/annotated"
# The sidecar's directory and every unit whose header targets include
# (model, blob).
(cd "$ANNOTATED_DIR" && cp -r model blob utf8 "$M/annotated/" && { [ -d "$M/annotated/$(dirname "$sidecar")" ] || cp -r "$(dirname "$sidecar")" "$M/annotated/"; })
replace() { "$TOIT_BIN" run "$REPO_ROOT/verified/tools/text_replace.toit" -- "$@"; }
# A change applies to the source and the sidecar's copy of the changed
# function alike; a change of an annotation only (a weaker contract) to the
# sidecar. Each must apply somewhere.
src_pairs=()
side_pairs=()
while [ $# -gt 0 ]; do
  # A change prefixed `SIDECAR::` applies to the sidecar only (several
  # copies of one template's text: one change per copy; annotations around
  # the changed code), `SOURCE::` to the source only.
  if [[ "$1" == SIDECAR::* ]]; then
    side_pairs+=("${1#SIDECAR::}" "$2")
    shift 2
    continue
  fi
  if [[ "$1" == SOURCE::* ]]; then
    src_pairs+=("${1#SOURCE::}" "$2")
    shift 2
    continue
  fi
  # (An `ANCHOR@@TEXT` change, text_replace.toit: TEXT's first line.)
  first="$(printf '%s' "$1" | sed 's/.*@@//; s/\\n.*//')"
  found=0
  if grep -qF -- "$first" "$M/repo/$source"; then src_pairs+=("$1" "$2"); found=1; fi
  if [ "$pattern" != DRIFT ] && grep -qF -- "$first" "$M/annotated/$sidecar"; then side_pairs+=("$1" "$2"); found=1; fi
  if [ $found = 0 ]; then
    printf 'FAIL  %-40s the mutation `%s` applies to neither %s nor the sidecar\n' "$name" "$first" "$source"
    exit 1
  fi
  shift 2
done
if [ ${#src_pairs[@]} -gt 0 ] && ! replace "$M/repo/$source" "${src_pairs[@]}" > "$M/replace.log"; then
  printf 'FAIL  %-40s the mutation does not apply to %s: %s\n' "$name" "$source" "$(cat "$M/replace.log")"
  exit 1
fi
if [ ${#side_pairs[@]} -gt 0 ] && ! replace "$M/annotated/$sidecar" "${side_pairs[@]}" > "$M/replace.log"; then
  printf 'FAIL  %-40s the mutation does not apply to the sidecar: %s\n' "$name" "$(cat "$M/replace.log")"
  exit 1
fi
cd "$M/annotated"
# The model is not mutated: its renderings (the copied ones, and the 32-bit
# ones render.sh made) are used as they are; only the sidecar is rendered.
mkdir -p "$M/gen32/$(dirname "$sidecar")"
cp -r "$GEN32/model" "$GEN32/blob" "$GEN32/utf8" "$M/gen32/"
# A primitive can use the verified contract of a sibling translation unit.
if [[ "$source" == verified/cxx/annotated/model/*.h ]]; then
  relative="${source#verified/cxx/annotated/}"
  cp "$M/repo/$source" "$M/annotated/$relative" || exit 1
  cp "$M/repo/$source" "$M/gen32/$relative" || exit 1
fi
for header in "$GEN32/$(dirname "$sidecar")"/*.gen.h; do
  if [ -f "$header" ]; then cp "$header" "$M/gen32/$(dirname "$sidecar")/"; fi
done
for f in $(ls "$(dirname "$sidecar")"/*.h "$(dirname "$sidecar")"/*.gh 2>/dev/null | grep -v '\.gen\.'); do
  cp "$f" "$M/gen32/$f"
done
"$ANNOTATED_DIR/prefetch-ast.sh" "$M/repo" "$M/scratch" "$sidecar" > "$M/prefetch.log" 2>&1
if ! "$TOIT_BIN" run "$REPO_ROOT/verified/tools/cxx_render.toit" -- --ast-ready --repo "$M/repo" \
    --scratch "$M/scratch" --target "i686-linux-gnu=$M/gen32" \
    "$sidecar" > "$M/render.log" 2>&1; then
  if [ "$pattern" = DRIFT ] && grep -q "DRIFT" "$M/render.log"; then
    printf 'ok    %-40s drift: %s\n' "$name" "$(grep -o "DRIFT: [^;]*" "$M/render.log" | head -1 | cut -c1-160)"
    exit 0
  fi
  if [[ "$pattern" == RENDER:* ]] && grep -qE "${pattern#RENDER:}" "$M/render.log"; then
    printf 'ok    %-40s render: %s\n' "$name" "$(grep -m1 FAIL "$M/render.log" | cut -c1-200)"
    exit 0
  fi
  printf 'FAIL  %-40s rendering failed: %s\n' "$name" "$(grep FAIL "$M/render.log" | head -1)"
  exit 1
fi
if [ "$pattern" = DRIFT ] || [[ "$pattern" == RENDER:* ]]; then
  printf 'FAIL  %-40s the changed source rendered without the expected error\n' "$name"
  exit 1
fi
# Rendered: VeriFast reads only annotated/ and gen32/; the AST dumps (most
# of the tree) go before the proofs, which take most of a mutant's time.
[ "${RUN_KEEP_MUTANTS:-0}" = 1 ] || rm -rf "$M/scratch"
gen="${sidecar%.render}.gen.c"
status=0
# A `TARGET:` prefix: only that target must fail, the other must verify.
only=""
if [[ "$pattern" =~ ^(LP64|ILP32):(.*)$ ]]; then
  only="${BASH_REMATCH[1]}"
  pattern="${BASH_REMATCH[2]}"
fi
for target in LP64 ILP32; do
  expect="$pattern"
  [ -n "$only" ] && [ "$target" != "$only" ] && expect=PASS
  dir="$M/annotated"
  [ "$target" = ILP32 ] && dir="$M/gen32"
  # shellcheck disable=SC2086
  out=$(cd "$dir" && "$VERIFAST" -c -target "$target" -fno-strict-aliasing -assume_left_to_right_evaluation $vfopts "$gen" 2>&1)
  vstatus=$?
  first=$(echo "$out" | grep -m1 -E "error|errors found" || true)
  if [ "$expect" = PASS ] && [ $vstatus -eq 0 ]; then
    printf 'ok    %-40s pass: %s\n' "$name/$target" "$first"
  elif [ "$expect" != PASS ] && [ $vstatus -ne 0 ] && echo "$first" | grep -qE "$expect"; then
    printf 'ok    %-40s fail: %s\n' "$name/$target" "$first"
  elif [ "$expect" = PASS ]; then
    printf 'FAIL  %-40s (expected it to verify): %s\n' "$name/$target" "$first"
    status=1
  else
    printf 'FAIL  %-40s (expected a failure matching %s): %s\n' "$name/$target" "$expect" "$first"
    status=1
  fi
done
exit $status
