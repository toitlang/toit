#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# The VeriFast matrix of the residual C++ (verified/cxx/annotated/README.md):
#   1. the renderings are what the current sources and sidecars give
#      (render.sh --check: drift fails here);
#   2. every constant they use has the value of the C++ headers, 64- and
#      32-bit (constants-check.sh);
#   3. VeriFast on every rendering, LP64 and ILP32, with its expected
#      verdict;
#   4. the reverted-bug self-tests (mutant.sh): each must fail where the
#      bug is;
#   5. the Rust raw-memory layer (VeriFast's Rust front end).
#
# Usage: run.sh [--quick] [FILTER]
#   FILTER: only the entries whose name contains it. --quick: no mutants.
# Exit status: 0 when every entry has its expected verdict. Exit status 3
# (and a SKIP line) when VeriFast is not installed (install-tools.sh).

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
QUICK=0
if [ "${1:-}" = --quick ]; then QUICK=1; shift; fi
filter="${1:-}"
cd "$ANNOTATED_DIR"

if [ ! -x "$VERIFAST" ]; then
  echo "SKIP: VeriFast $VERIFAST_VERSION is not installed at $VERIFAST_DIR (verified/cxx/annotated/install-tools.sh)"
  exit 3
fi
mkdir -p "$ACXX_HOME/logs"

failures=0
note() { if [ "$1" -ne 0 ]; then failures=$((failures + 1)); fi; }

# 1, 2.
if [ -z "$filter" ]; then
  if ./render.sh --check > "$ACXX_HOME/logs/render.log" 2>&1; then
    printf 'ok    %-40s %s\n' render "$(grep -c '^ok' "$ACXX_HOME/logs/render.log") sidecars match the sources"
  else
    printf 'FAIL  %-40s\n' render
    grep -v '^ok' "$ACXX_HOME/logs/render.log" | head -20
    failures=$((failures + 1))
  fi
  ./constants-check.sh
  note $?
fi

# The options every C file is verified with: -fno-strict-aliasing (the
# object words are typed by the chunks, not by C's effective types),
# -assume_left_to_right_evaluation (a call inside an expression, as the
# C++ writes it).
OPTS=(-fno-strict-aliasing -assume_left_to_right_evaluation)

# entry NAME EXPECT(pass|fail) EXPECTED-ERROR-REGEX FILE [EXTRA OPTIONS...]
# A generated FILE (*.gen.c) is verified for ILP32 in its 32-bit rendering.
entry() {
  local name="$1" expect="$2" pattern="$3" file="$4"; shift 4
  for target in LP64 ILP32; do
    local full="$name/$target"
    [[ -n "$filter" && "$full" != *"$filter"* ]] && continue
    local dir="$ANNOTATED_DIR"
    [[ "$target" = ILP32 && "$file" = *.gen.c ]] && dir="$GEN32"
    local out status start end
    start=$(date +%s%N)
    out=$(cd "$dir" && "$VERIFAST" -c -target "$target" "${OPTS[@]}" "$@" "$file" 2>&1)
    status=$?
    end=$(date +%s%N)
    local verdict=pass
    [ $status -ne 0 ] && verdict=fail
    local first
    first=$(echo "$out" | grep -m1 -E "error|errors found" || true)
    local t
    t=$(printf '%d.%02d s' $(((end - start) / 1000000000)) $((((end - start) / 10000000) % 100)))
    if [ "$verdict" = "$expect" ] && { [ "$expect" = pass ] || echo "$first" | grep -qE "$pattern"; }; then
      printf 'ok    %-40s %s %s: %s\n' "$full" "$verdict" "$t" "$first"
    else
      printf 'FAIL  %-40s %s (expected %s %s): %s\n' "$full" "$verdict" "$expect" "$pattern" "$first"
      failures=$((failures + 1))
    fi
  done
}

# mutant NAME SIDECAR SOURCE PATTERN "VERIFAST OPTIONS" FROM TO [FROM TO]...
mutant() {
  [ "$QUICK" = 1 ] && return
  [[ -n "$filter" && "$1" != *"$filter"* ]] && return
  ./mutant.sh "$@"
  note $?
}

# 3. The renderings.
entry model                 pass "" model/objects.gen.c
entry encoder               pass "" encoder/message_encoder.gen.c

# 4. Reverted bugs. f708ad5d (message encoder bounds):
# - encode_array with only the release-dropped ASSERT(from <= to): the
#   negative element count of a slice with to < from;
mutant f708ad5d-count encoder/message_encoder.render src/messaging.cc "underflow" "" \
  "if (from < 0 || from > to || to > object->length()) return false;" "ASSERT(from <= to);"
# - without the length check: the read past the backing array (the loop
#   cannot keep `to <= length`);
mutant f708ad5d-read encoder/message_encoder.render src/messaging.cc "to <= o_len|index < o_len" "" \
  "if (from < 0 || from > to || to > object->length()) return false;" "if (from < 0 || from > to) return false;"
# - encode_map without the bound on the backing: the read past it.
mutant f708ad5d-map encoder/message_encoder.render src/messaging.cc "i < o_len" "" \
  "count < size && i + 1 < limit; i += 2)" "count < size; i += 2)"

entry utf8                  pass "" utf8/utf_8_to_16.gen.c -prover z3v4.5
# 07c24665 (UTF-8 decoding read past the input) reverted: the first byte
# announcing 1 or more than 4 bytes reaches payload_from_prefix (the UB
# shift `1 << (7 - 8)` the first pilot's tools found)...
mutant utf8-07c24665 utf8/utf_8_to_16.render src/utils.cc "utf8_count" "-prover z3v4.5" \
  "if (prefix > Utils::MAX_ASCII && (count < 2 || count > 4 || count > length - i)) {\n      c = 0xfffd;\n      count = 1;\n    } else if (prefix > Utils::MAX_ASCII) {" \
  "if (prefix > Utils::MAX_ASCII) {"
# ... and with only its length check taken out, the read past the end at
# `input[i + j]`.
mutant utf8-overread utf8/utf_8_to_16.render src/utils.cc "No matching array chunk|i \+ j" "-prover z3v4.5" \
  "count > 4 || count > length - i)" "count > 4)"

# Hand renderings of the pilot (not yet generated, not drift-checked).
entry string-write          pass "" prims/string_write.c
entry string-write-af4ba7ab fail "No matching heap chunks: uchars_" prims/string_write.c -allow_assume -allow_dead_code -D AF4BA7AB_REVERTED
entry string-write-af4ba7ab-disjoint pass "" prims/string_write.c -allow_assume -allow_dead_code -D AF4BA7AB_REVERTED -D AF4BA7AB_DISJOINT
entry grow-stack            pass "" grow/grow_stack.c -prover z3v4.5
entry grow-stack-unbounded  fail "grow_stack.c.*(overflow|underflow)" grow/grow_stack.c -prover z3v4.5 -D NEEDED_UNBOUNDED
entry grow-stack-word-range fail "grow_stack.c.*overflow" grow/grow_stack.c -prover z3v4.5 -D NEEDED_WORD_RANGE

# 5. The Rust side (VeriFast's Rust front end, host target only).
rust_entry() {
  local name="$1" expect="$2" file="$3"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return
  if [ ! -d "$ACXX_HOME/tools/rustup" ]; then
    printf 'SKIP  %-40s no VeriFast Rust toolchain\n' "$name"
    return
  fi
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
sed 's|internal_string(obj, ?len) \&\*\& i < len;|internal_string(obj, ?len) \&*\& i <= len;|' \
  rust/view_accessors.rs > "$ACXX_HOME/logs/view_accessors_neg.rs"
rust_entry rust-view-index-at-length fail "$ACXX_HOME/logs/view_accessors_neg.rs"

echo "failures: $failures"
exit $((failures > 0))
