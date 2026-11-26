#!/usr/bin/env bash
# Lists the language-boundary signatures of a device library build:
# every external function the Rust code declares and calls (Rust -> C,
# including ROM/libc/libm/libgcc), and every exported (external linkage,
# non-mangled or C-callable) function it defines (C -> Rust). For each it
# prints the number of argument words in the Xtensa windowed ABI (a2-a7
# hold six; 64-bit values take an aligned pair) and flags stack-passed
# arguments that are sub-word integers or byval objects whose size is not
# a multiple of 4 (esp-rs/rust#278).
# Usage: ffi-signatures.sh <devlib-name>
set -euo pipefail
NAME=$1
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes
D=$ROOT/devlib/$NAME
mkdir -p "$D/ll"
for f in "$D"/bc/*.bc; do
  "$ROOT/llvm-build/bin/llvm-dis" "$f" -o "$D/ll/$(basename "$f" .bc).ll"
done
# Declarations used by calls and exported definitions (not internal/private,
# not Rust-mangled _R/_ZN names, not intrinsics).
cat "$D"/ll/*.ll | grep -E '^(declare|define) ' \
  | grep -v -E '@llvm\.' \
  | grep -v -E '^define (internal|private|hidden internal|linkonce|weak)' \
  | awk '
  function words(ty,   n) {
    if (ty ~ /^(i64|double)/) return 2
    if (ty ~ /^i128/) return 4
    return 1
  }
  {
    kind = $1
    line = $0
    name = line; sub(/^[^@]*@/, "", name); sub(/\(.*/, "", name)
    if (name ~ /^_R/ || name ~ /^_ZN/) next
    args = line; sub(/^[^(]*\(/, "", args); sub(/\)[^)]*$/, "", args)
    # The argument list up to the closing paren of the parameter list.
    depth = 0; cur = ""; n = 0; delete a
    for (i = 1; i <= length(args); i++) {
      c = substr(args, i, 1)
      if (c == "(" || c == "{" || c == "[" || c == "<") depth++
      if (c == ")" || c == "}" || c == "]" || c == ">") depth--
      if (c == "," && depth == 0) { a[++n] = cur; cur = ""; continue }
      cur = cur c
    }
    if (cur != "") a[++n] = cur
    w = 0; flags = ""
    for (j = 1; j <= n; j++) {
      t = a[j]; sub(/^ +/, "", t)
      if (t == "...") { flags = flags " varargs"; continue }
      ww = words(t)
      if (ww == 2 && w % 2 == 1) w++
      if (t ~ /byval/) {
        flags = flags " byval[" t "]"
      }
      if (w + ww > 6) {
        if (t ~ /^i(8|16)( |$)/) flags = flags " STACK-SUBWORD(arg" j ":" t ")"
        if (t ~ /byval/) flags = flags " STACK-BYVAL(arg" j ")"
      }
      w += ww
    }
    printf "%s %s words=%d%s\n", kind, name, w, flags
  }' | sort -u > "$D/ffi-signatures.txt"
wc -l < "$D/ffi-signatures.txt"
awk '{ split($3, x, "="); if (x[2] > 6 || $0 ~ /STACK|byval/) print }' "$D/ffi-signatures.txt"
