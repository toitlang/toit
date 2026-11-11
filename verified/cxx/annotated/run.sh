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

# The entries run as parallel jobs (at most one per core); their output is
# printed in order at the end. A job's exit status is its failure count.
JOBS="$ACXX_HOME/logs/run-jobs"
rm -rf "$JOBS"
mkdir -p "$JOBS"
MAXJOBS="${RUN_JOBS:-$(nproc)}"
njobs=0
pids=()
spawn() {
  while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do wait -n; done
  ("$@") > "$JOBS/$njobs.log" 2>&1 &
  pids+=($!)
  njobs=$((njobs + 1))
}

# entry NAME EXPECT(pass|fail) EXPECTED-ERROR-REGEX FILE [EXTRA OPTIONS...]
# A generated FILE (*.gen.c) is verified for ILP32 in its 32-bit rendering.
entry() { spawn entry_run "$@"; }
entry_run() {
  local failures=0
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
  return $failures
}

# mutant NAME SIDECAR SOURCE PATTERN "VERIFAST OPTIONS" FROM TO [FROM TO]...
mutant() {
  [ "$QUICK" = 1 ] && return
  [[ -n "$filter" && "$1" != *"$filter"* ]] && return
  spawn ./mutant.sh "$@"
}

# The correspondence check's self-tests: a rendered function changed in the
# source only (an off-by-one in a bound; a strict comparison made non-strict) must
# fail as drift.
mutant drift-encoder encoder/message_encoder.render src/messaging.cc DRIFT "" \
  "to > object->length()) return false;" "to > object->length() + 1) return false;"
mutant drift-utf8 utf8/utf_8_to_16.render src/utils.cc DRIFT "" \
  "    if (c < 0x10000) {" "    if (c <= 0x10000) {"

# 3. The renderings.
entry translator-rules      pass "" tests/rules.gen.c
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

entry byte-content          pass "" blob/byte_content.gen.c
# 357d1127 (#3373, byte_content nesting) reverted: without the depth limit
# the recursive call's precondition (depth + 1 <= MAX) fails.
mutant byte-content-357d1127 blob/byte_content.render src/objects.cc "depth" "" \
  "    if (depth >= MAX_BYTE_CONTENT_DEPTH) return false;\n    auto instance" "    auto instance"
# A slice's `to` not checked against the content: the pointer leaves the blob.
mutant byte-content-slice-to blob/byte_content.render src/objects.cc "pointer_within_limits|blob_in" "" \
  "from_value <= to_value && to_value <= *length) {" "from_value <= to_value) {"

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

entry grow-stack            pass "" grow/grow_stack.gen.c -prover z3v4.5
# The bound on `needed` (core/trusted-integration) taken out again: the
# cast to word overflows; with only the cast made exact by a precondition,
# the sum.
mutant grow-stack-unbounded grow/grow_stack.render src/interpreter_v2.cc "overflow|underflow" "-prover z3v4.5" \
  "  if (needed > static_cast<uword>(Stack::max_length())) return TOIT_V2_STACK_OVERFLOW;\n" ""
mutant grow-stack-word-range grow/grow_stack.render src/interpreter_v2.cc "overflow" "-prover z3v4.5" \
  "  if (needed > static_cast<uword>(Stack::max_length())) return TOIT_V2_STACK_OVERFLOW;\n" "" \
  "stack_ok(len, top, rtop, bs) == true; @*/\n/*@ ensures current_stack" "stack_ok(len, top, rtop, bs) == true &*& needed <= UINTPTR_MAX / 2; @*/\n/*@ ensures current_stack"

entry string-write          pass "" prims/string_write.gen.c -prover z3v4.5
# af4ba7ab (memcpy for a copy within one byte array) reverted: no proof...
mutant string-write-af4ba7ab prims/string_write.render src/primitive_core.cc "No matching heap chunks: uchars_" "-prover z3v4.5" \
  "  memmove(&dest.address()[dest_index]" "  memcpy(&dest.address()[dest_index]"
# ... and with the two ranges assumed to be in different byte arrays
# (separate chunks for memcpy), the same memcpy verifies: the failure is
# the overlap.
mutant string-write-af4ba7ab-disjoint prims/string_write.render src/primitive_core.cc PASS "-allow_assume -allow_dead_code -prover z3v4.5" \
  "  memmove(&dest.address()[dest_index]" "  memcpy(&dest.address()[dest_index]" \
  "  //@ if (bs != bd) blob_take(bs);" "  //@ assume(bs != bd);\n  //@ blob_take(bs);" \
  "    close mm_pre(mm_two, d, s, to - from);\n" "" \
  "    open mm_post(_, _, _, _);\n    uchars_join(s);" "    uchars_join(s);"

# The MutableBlob decoding. `-allow_dead_code`: the check `content == null`
# (README, "Findings") is dead, VeriFast proves it.
entry mutable-byte-content  pass "" blob/mutable_byte_content.gen.c -allow_dead_code -prover z3v4.5
# 357d1127 reverted in mutable_byte_content: the recursive call fails.
mutant mutable-byte-content-357d1127 blob/mutable_byte_content.render src/objects_runtime.cc "depth" "-allow_dead_code -prover z3v4.5" \
  "  if (depth >= MAX_BYTE_CONTENT_DEPTH) return false;\n" ""
# Without the program-heap check a read-only object is written.
mutant mutable-byte-content-program-heap blob/mutable_byte_content.render src/objects_runtime.cc "in_program_heap|mutable_result" "-allow_dead_code -prover z3v4.5" \
  "  if (is_heap_object(this) && HeapObject::cast(this)->on_program_heap(process)) {" "  if (false) {"
# Without the external tag check a proxy's struct is handed out as bytes
# (both decoders).
mutant mutable-byte-content-external-tag blob/mutable_byte_content.render src/objects_runtime.cc "blob_ok|mutable_result|external_bytes|uchars" "-allow_dead_code -prover z3v4.5" \
  "    if (byte_array->has_external_address() && byte_array->external_tag() != RawByteTag) return false;\n    ByteArray::Bytes bytes" "    ByteArray::Bytes bytes"
mutant byte-content-external-tag blob/byte_content.render src/objects.cc "blob_ok|blob_result|external_bytes|uchars" "" \
  "    if (byte_array->has_external_address() && byte_array->external_tag() != RawByteTag) return false;\n    ByteArray::ConstBytes bytes" "    ByteArray::ConstBytes bytes"

# 5. The Rust side (VeriFast's Rust front end, host target only).

rust_entry_run() {
  local failures=0
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
  return $failures
}
# (One job: the Rust front end builds in one cargo directory.)
rust_entries() {
  local f=0
  rust_entry_run rust-view pass rust/view_accessors.rs || f=$((f + $?))
  sed 's|internal_string(obj, ?len) \&\*\& i < len;|internal_string(obj, ?len) \&*\& i <= len;|' \
    rust/view_accessors.rs > "$ACXX_HOME/logs/view_accessors_neg.rs"
  rust_entry_run rust-view-index-at-length fail "$ACXX_HOME/logs/view_accessors_neg.rs" || f=$((f + $?))
  # The like-for-like trial (README, "The Rust raw-memory layer"): of the
  # five accessors, class_id and class_tag stop VeriFast's Rust front end
  # ("Todo: BinOp::Shr"); the other three verify.
  sed '/pub unsafe fn class_id/,/^    }$/d' rust/view_trial.rs | sed '/pub unsafe fn class_tag/,/^    }$/d' \
    > "$ACXX_HOME/logs/view_trial_noshift.rs"
  rust_entry_run rust-trial-three pass "$ACXX_HOME/logs/view_trial_noshift.rs" || f=$((f + $?))
  return $f
}
# The same five in Verus, with vstd::raw_ptr permissions.
verus_trial() {
  [[ -n "$filter" && "verus-trial" != *"$filter"* ]] && return 0
  if ! command -v verus > /dev/null; then
    printf 'SKIP  %-40s no verus\n' verus-trial
    return 0
  fi
  local out
  out=$(cd rust && verus --crate-type=lib verus_pptr.rs 2>&1)
  if echo "$out" | grep -q "verification results:: [0-9]* verified, 0 errors"; then
    printf 'ok    %-40s pass: %s\n' verus-trial "$(echo "$out" | grep 'verification results')"
    return 0
  fi
  printf 'FAIL  %-40s %s\n' verus-trial "$(echo "$out" | grep -m1 -E 'error|verification results')"
  return 1
}
spawn verus_trial
spawn rust_entries

for i in "${!pids[@]}"; do
  wait "${pids[$i]}"
  s=$?
  [ $s -ne 0 ] && failures=$((failures + s))
  cat "$JOBS/$i.log"
done
echo "failures: $failures"
exit $((failures > 0))
