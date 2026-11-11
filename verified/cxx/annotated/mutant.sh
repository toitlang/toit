#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# A reverted-bug self-test: applies a source change (e.g. a past fix taken
# out again) to a copy of the repository and to a copy of the sidecar
# alike, renders that copy and runs VeriFast on it. The proof must then
# fail, with the expected error.
#
# Usage: mutant.sh NAME SIDECAR SOURCE PATTERN "VERIFAST OPTIONS" FROM TO [FROM TO]...
#   SIDECAR relative to this directory, SOURCE relative to the repository.
#   FROM/TO: literal texts (`\n` a newline); each must occur exactly once in
#   SOURCE and, if it occurs there at all, once in the sidecar.
# Prints one line `ok` / `FAIL` like run.sh; exit status 0 when the proof
# failed with PATTERN on both LP64 and ILP32.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
name="$1"; sidecar="$2"; source="$3"; pattern="$4"; vfopts="$5"; shift 5
TOIT_BIN="${TOIT:-$REPO_ROOT/build/host/sdk/bin/toit}"
[ -x "$TOIT_BIN" ] || TOIT_BIN="$(command -v toit)"

M="$ACXX_HOME/mutants/$name"
rm -rf "$M"
mkdir -p "$M/repo/src" "$M/scratch" "$M/gen32"
for e in "$REPO_ROOT"/*; do
  [ "$(basename "$e")" = src ] || ln -s "$e" "$M/repo/$(basename "$e")"
done
for e in "$REPO_ROOT"/src/*; do ln -s "$e" "$M/repo/src/$(basename "$e")"; done
rm "$M/repo/src/$(basename "$source")"
cp "$REPO_ROOT/$source" "$M/repo/$source"
mkdir -p "$M/annotated"
(cd "$ANNOTATED_DIR" && cp -r model "$(dirname "$sidecar")" "$M/annotated/")
replace() { "$TOIT_BIN" run "$REPO_ROOT/verified/tools/text_replace.toit" -- "$@"; }
if ! replace "$M/repo/$source" "$@" > "$M/replace.log"; then
  printf 'FAIL  %-40s the mutation does not apply to %s: %s\n' "$name" "$source" "$(cat "$M/replace.log")"
  exit 1
fi
# The sidecar's copy of the changed functions changes alike.
pairs=()
while [ $# -gt 0 ]; do
  if grep -qF -- "$(printf '%b' "${1//\\n/\\n}" | head -1)" "$M/annotated/$sidecar"; then
    pairs+=("$1" "$2")
  fi
  shift 2
done
if [ ${#pairs[@]} -gt 0 ] && ! replace "$M/annotated/$sidecar" "${pairs[@]}" > "$M/replace.log"; then
  printf 'FAIL  %-40s the mutation does not apply to the sidecar: %s\n' "$name" "$(cat "$M/replace.log")"
  exit 1
fi
cd "$M/annotated"
for f in $(ls */*.h */*.gh | grep -v '\.gen\.'); do
  mkdir -p "$M/gen32/$(dirname "$f")"
  cp "$f" "$M/gen32/$f"
done
if ! "$TOIT_BIN" run "$REPO_ROOT/verified/tools/cxx_render.toit" -- --repo "$M/repo" \
    --scratch "$M/scratch" --target "i686-linux-gnu=$M/gen32" \
    model/objects.render "$sidecar" > "$M/render.log" 2>&1; then
  printf 'FAIL  %-40s rendering failed: %s\n' "$name" "$(grep FAIL "$M/render.log" | head -1)"
  exit 1
fi
gen="${sidecar%.render}.gen.c"
status=0
for target in LP64 ILP32; do
  dir="$M/annotated"
  [ "$target" = ILP32 ] && dir="$M/gen32"
  # shellcheck disable=SC2086
  out=$(cd "$dir" && "$VERIFAST" -c -target "$target" -fno-strict-aliasing -assume_left_to_right_evaluation $vfopts "$gen" 2>&1)
  vstatus=$?
  first=$(echo "$out" | grep -m1 -E "error|errors found" || true)
  if [ $vstatus -ne 0 ] && echo "$first" | grep -qE "$pattern"; then
    printf 'ok    %-40s fail: %s\n' "$name/$target" "$first"
  else
    printf 'FAIL  %-40s (expected a failure matching %s): %s\n' "$name/$target" "$pattern" "$first"
    status=1
  fi
done
exit $status
