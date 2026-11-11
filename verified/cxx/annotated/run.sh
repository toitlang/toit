#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# The matrix of the second C++ pilot (verified/CXX-ANNOTATED-PILOT.md):
# every VeriFast run with its expected verdict, on 64-bit and 32-bit.
#
# Usage: run.sh [FILTER]   (runs the entries whose name contains FILTER)
# Exit status: 0 when every entry has its expected verdict.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
filter="${1:-}"
cd "$ANNOTATED_DIR"

# The options every C file is verified with: see the write-up, "The C
# rendering" (-fno-strict-aliasing: the object words are typed by the
# chunks, not by C's effective types; -assume_left_to_right_evaluation:
# allows a call inside an expression, as the C++ writes it).
OPTS=(-fno-strict-aliasing -assume_left_to_right_evaluation)

failures=0
# entry NAME EXPECT(pass|fail) EXPECTED-ERROR-REGEX FILE [EXTRA OPTIONS...]
entry() {
  local name="$1" expect="$2" pattern="$3" file="$4"; shift 4
  for target in LP64 ILP32; do
    local full="$name/$target"
    [[ -n "$filter" && "$full" != *"$filter"* ]] && continue
    local out
    out=$("$VERIFAST" -c -target "$target" "${OPTS[@]}" "$@" "$file" 2>&1)
    local status=$?
    local verdict=pass
    [ $status -ne 0 ] && verdict=fail
    local first
    first=$(echo "$out" | grep -m1 -E "error|errors found" || true)
    if [ "$verdict" = "$expect" ] && { [ "$expect" = pass ] || echo "$first" | grep -qE "$pattern"; }; then
      printf 'ok    %-40s %s: %s\n' "$full" "$verdict" "$first"
    else
      printf 'FAIL  %-40s %s (expected %s %s): %s\n' "$full" "$verdict" "$expect" "$pattern" "$first"
      failures=$((failures + 1))
    fi
  done
}

entry model                 pass "" model/objects.c
entry encoder               pass "" encoder/message_encoder.c
# f708ad5d reverted: the first error is the negative element count of a
# slice with to < from (`write_cardinal(to - from)`, the second bug of the
# commit message), at the conversion to uword.
entry encoder-f708ad5d      fail "message_encoder.c\(3[0-9][0-9],.*(underflow|overflow)" encoder/message_encoder.c -D F708AD5D_REVERTED
# The same with the release-dropped ASSERT(from <= to) assumed: the read
# past the backing array (the first bug), at `object->at(i)`.
entry encoder-f708ad5d-read fail "objects.h.*index < len|Cannot prove i < " encoder/message_encoder.c -D F708AD5D_REVERTED -D ASSUME_FROM_LE_TO

entry utf8                  pass "" utf8/utf_8_to_16.c -prover z3v4.5
# 07c24665 reverted: payload_from_prefix for a first byte announcing 1 or
# more than 4 bytes (the UB shift `1 << (7 - 8)` the pilot-1 tools found).
entry utf8-07c24665         fail "utf_8_to_16.c.*(utf8_count|payload)|Cannot prove 2 <= utf8_count" utf8/utf_8_to_16.c -prover z3v4.5 -D UTF8_OVERREAD_REVERTED

# Only the `count > length - i` part of the fix taken out: the read past
# the end of the input, at `input[i + j]`.
entry utf8-overread         fail "utf_8_to_16.c.*(No matching|array|i \+ j)" utf8/utf_8_to_16.c -prover z3v4.5 -D UTF8_LENGTH_CHECK_REMOVED

entry string-write          pass "" prims/string_write.c
# af4ba7ab reverted (memcpy): no proof for overlapping ranges of one byte
# array; with non-overlap assumed, the same mutant verifies.
entry string-write-af4ba7ab fail "No matching heap chunks: uchars_" prims/string_write.c -allow_assume -allow_dead_code -D AF4BA7AB_REVERTED
entry string-write-af4ba7ab-disjoint pass "" prims/string_write.c -allow_assume -allow_dead_code -D AF4BA7AB_REVERTED -D AF4BA7AB_DISJOINT

entry grow-stack            pass "" grow/grow_stack.c -prover z3v4.5
# The Verus contract as it is (no bound on `needed`): the cast to word.
entry grow-stack-unbounded  fail "grow_stack.c.*(overflow|underflow)" grow/grow_stack.c -prover z3v4.5 -D NEEDED_UNBOUNDED
# Only the cast made exact: the sum (length - free) + needed.
entry grow-stack-word-range fail "grow_stack.c.*overflow" grow/grow_stack.c -prover z3v4.5 -D NEEDED_WORD_RANGE

# The Rust side (VeriFast's Rust front end, host target only): two
# accessors of verified/core/src/view.rs; the negative copy allows i == len.
rust_entry() {
  local name="$1" expect="$2" file="$3"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return
  local out status verdict=pass
  out=$(RUSTUP_HOME="$ACXX_HOME/tools/rustup" CARGO_HOME="$ACXX_HOME/tools/cargo" "$VERIFAST" -allow_dead_code "$file" 2>&1)
  status=$?
  [ $status -ne 0 ] && verdict=fail
  local first
  first=$(echo "$out" | grep -m1 -E "error|errors found" || true)
  if [ "$verdict" = "$expect" ]; then
    printf 'ok    %-40s %s: %s\n' "$name" "$verdict" "$first"
  else
    printf 'FAIL  %-40s %s (expected %s): %s\n' "$name" "$verdict" "$expect" "$first"
    failures=$((failures + 1))
  fi
}
rust_entry rust-view pass rust/view_accessors.rs
mkdir -p "$ACXX_HOME/logs"
sed 's|internal_string(obj, ?len) \&\*\& i < len;|internal_string(obj, ?len) \&*\& i <= len;|' \
  rust/view_accessors.rs > "$ACXX_HOME/logs/view_accessors_neg.rs"
rust_entry rust-view-index-at-length fail "$ACXX_HOME/logs/view_accessors_neg.rs"

echo "failures: $failures"
exit $((failures > 0))
