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
acxx_lock
QUICK=0
if [ "${1:-}" = --quick ]; then QUICK=1; shift; fi
filter="${1:-}"
cd "$ANNOTATED_DIR"

if [ ! -x "$VERIFAST" ]; then
  echo "SKIP: VeriFast $VERIFAST_VERSION is not installed at $VERIFAST_DIR (verified/cxx/annotated/install-tools.sh)"
  exit 3
fi
mkdir -p "$ACXX_WORK/logs"

failures=0
note() { if [ "$1" -ne 0 ]; then failures=$((failures + 1)); fi; }

# The options every C file is verified with: -fno-strict-aliasing (the
# object words are typed by the chunks, not by C's effective types),
# -assume_left_to_right_evaluation (a call inside an expression, as the
# C++ writes it).
OPTS=(-fno-strict-aliasing -assume_left_to_right_evaluation)

# Every check runs as a parallel job (at most one per core); the output is
# printed in order at the end. A job's exit status is its failure count.
# Two phases: render.sh --check rewrites the 32-bit renderings (under
# $GEN32; the committed 64-bit ones it only compares), so it runs together
# with the LP64 proofs, and the ILP32 proofs and the mutants (which copy
# the 32-bit model) start when it is done.
JOBS="$ACXX_WORK/logs/run-jobs"
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
# The second phase's jobs, in order, each as a quoted command line.
deferred=()
defer() {
  deferred+=("$(printf '%q ' "$@")")
}

# 1, 2.
render_check() {
  local f=0
  if ./render.sh --check > "$ACXX_WORK/logs/render.log" 2>&1; then
    printf 'ok    %-40s %s\n' render "$(grep -c '^ok' "$ACXX_WORK/logs/render.log") sidecars match the sources"
  else
    printf 'FAIL  %-40s\n' render
    grep -v '^ok' "$ACXX_WORK/logs/render.log" | head -20
    f=1
  fi
  ./constants-check.sh || f=$((f + 1))
  return $f
}
render_pid=""
if [ -z "$filter" ]; then
  spawn render_check
  render_pid="${pids[-1]}"
fi

# entry NAME EXPECT(pass|fail) EXPECTED-ERROR-REGEX FILE [EXTRA OPTIONS...]
# A generated FILE (*.gen.c) is verified for ILP32 in its 32-bit rendering.
# LP64 now, ILP32 in the second phase.
entry() {
  spawn entry_run LP64 "$@"
  defer entry_run ILP32 "$@"
}
entry_run() {
  local failures=0
  local only="$1"; shift
  local name="$1" expect="$2" pattern="$3" file="$4"; shift 4
  for target in "$only"; do
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
  defer ./mutant.sh "$@"
}

# The correspondence check's self-tests: a rendered function changed in the
# source only (an off-by-one in a bound; a strict comparison made non-strict) must
# fail as drift.
mutant drift-encoder encoder/message_encoder.render src/messaging.cc DRIFT "" \
  "to > object->length()) return false;" "to > object->length() + 1) return false;"
mutant drift-utf8 utf8/utf_8_to_16.render src/utils.cc DRIFT "" \
  "    if (c < 0x10000) {" "    if (c <= 0x10000) {"

# 3. The renderings.
entry translator-rules      pass "" tests/rules.gen.c -allow_dead_code
entry model                 pass "" model/objects.gen.c
entry encoder               pass "" encoder/message_encoder.gen.c
# The bound of write_cardinal's bytes (encoder/cardinal.h), with Z3.
entry cardinal              pass "" encoder/cardinal.c -prover z3v4.5

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
# The 32-bit size fix (README, "Findings"): a blob checked against twice
# what is left: the sizes leave the bound (on ILP32 they overflowed).
mutant encoder-copy-size encoder/message_encoder.render src/messaging.cc "1073741823 \+ 32|overflow" "" \
  "if (length > MESSAGING_ENCODING_MAX_SIZE - total_size()) {" \
  "if (length > MESSAGING_ENCODING_MAX_SIZE + MESSAGING_ENCODING_MAX_SIZE - total_size()) {"
# ... and the same for a transferred byte array.
mutant encoder-transfer-size encoder/message_encoder.render src/messaging.cc "1073741823 \+ 32|overflow" "" \
  "if (bytes.length() > MESSAGING_ENCODING_MAX_SIZE - total_size()) {" \
  "if (bytes.length() > MESSAGING_ENCODING_MAX_SIZE + MESSAGING_ENCODING_MAX_SIZE - total_size()) {"
# The external tables: one reservation too many writes past copied_ or
# transferred_.
mutant encoder-externals-bound encoder/message_encoder.render src/messaging.cc "<= 8" "" \
  "if (externals_count_ >= MESSAGING_ENCODING_MAX_EXTERNALS) {" "if (externals_count_ > MESSAGING_ENCODING_MAX_EXTERNALS) {"
# The string copy's terminator read from the content (README, "Findings"):
# one byte past the blob.
mutant encoder-copy-terminator encoder/message_encoder.render src/messaging.cc "No matching heap chunks: \[_\]chars" "" \
  "memcpy(data, source, length);" "memcpy(data, source, length + extra);"

# The message decoder (TISON from untrusted bytes; IPC under the two named
# assumptions). `-allow_dead_code`: the `return null` after decode_any's
# switch (every case returns).
DEC_OPTS="-allow_dead_code -prover z3v4.5"
entry decoder               pass "" decoder/message_decoder.gen.c -allow_dead_code -prover z3v4.5
# The bound of read_cardinal's digits (decoder/radix.h), with Z3.
# `-allow_dead_code`: on ILP32 the cases of the shifts above 28.
entry radix                 pass "" decoder/radix.c -allow_dead_code -prover z3v4.5
# The length checks before the inline copies: the copy leaves the input.
mutant decoder-string-length decoder/message_decoder.render src/messaging.cc "result (63|31)\)\) cap" "$DEC_OPTS" \
  "MessageDecoder::decode_string(bool inlined)@@if (length < 0 || length > remaining()) return mark_malformed();" "if (length < 0) return mark_malformed();"
mutant decoder-byte-array-length decoder/message_decoder.render src/messaging.cc "1073741823" "$DEC_OPTS" \
  "MessageDecoder::decode_byte_array(bool inlined)@@if (length < 0 || length > remaining()) return mark_malformed();" "if (length < 0) return mark_malformed();"
# The length checks before the array and map allocations: an allocation
# larger than the input left.
mutant decoder-array-length decoder/message_decoder.render src/messaging.cc "result (63|31)\) \(- cap" "$DEC_OPTS" \
  "if (length < 0 || length > remaining() || length > Array::max_length_in_process()) {" "if (length < 0 || length > Array::max_length_in_process()) {"
mutant decoder-map-length decoder/message_decoder.render src/messaging.cc "\(\* 2 \(truncate_signed result (63|31)\)\) \(- cap" "$DEC_OPTS" \
  "if (size < 0 || size > remaining() / 2 || size > Array::max_length_in_process() / 2) {" "if (size < 0 || size > Array::max_length_in_process() / 2) {"
# The nesting limit (#3362) taken out: the recursion is unbounded.
mutant decoder-nesting decoder/message_decoder.render src/messaging.cc "n 1\) 64" "$DEC_OPTS" \
  "  if (nesting_ > MESSAGING_DECODING_MAX_NESTING) return mark_malformed();\n" ""
# The fixed-size readers' bound: a read past the input.
mutant decoder-uint64-bound decoder/message_decoder.render src/messaging.cc "8 \(- cap c\)" "$DEC_OPTS" \
  "MessageDecoder::read_uint64()@@if (next <= size_) {" "if (next <= size_ + 1) {"
# read_uint8, in the header (mutant.sh copies the changed header into the
# mutant's src/): the byte at the end of the input is read.
mutant decoder-uint8-bound decoder/message_decoder.render src/messaging.h "No matching|uchars|cap" "$DEC_OPTS" \
  "return (cursor < size_) ? buffer_[cursor] : 0;" "return (cursor <= size_) ? buffer_[cursor] : 0;"
# read_cardinal_64: without the size check (#3362) the shift is
# undefined; without the digit check (wave 3) the sum wraps.
mutant decoder-cardinal-shift decoder/message_decoder.render src/messaging.cc "shift|7 \* k|digit|overflow" "$DEC_OPTS" \
  "if (shift >= 64 || digit > (UINT64_MAX >> shift)) {" "if (digit > (UINT64_MAX >> shift)) {"
mutant decoder-cardinal-digit decoder/message_decoder.render src/messaging.cc "18446744073709551615|overflow|digit" "$DEC_OPTS" \
  "if (shift >= 64 || digit > (UINT64_MAX >> shift)) {" "if (shift >= 64) {"
# read_cardinal: a 64-bit cardinal is not a word on ILP32 (on LP64 the
# check is dead): without the check the conversion to uword overflows.
mutant decoder-cardinal-word decoder/message_decoder.render src/messaging.cc "ILP32:overflow|truncat|uword" "$DEC_OPTS" \
  "  if (result > UINTPTR_MAX) {\n    mark_malformed();\n    return 0;\n  }\n  return static_cast<uword>(result);" "  return static_cast<uword>(result);"
# Finding 3 (wave 4): the smi tags' magnitude above INT64_MAX (the
# conversion to int64 overflows); without the smi range check in
# decode_integer a value in the smi range is allocated as a large integer
# (not canonical: the allocator contract's `canonical` clause fails).
mutant decoder-smi-magnitude decoder/message_decoder.render src/messaging.cc "overflow|int64|9223372036854775807" "$DEC_OPTS" \
  "case TAG_POSITIVE_SMI: {\n      uint64 value = read_cardinal_64();\n      if (value > static_cast<uint64>(INT64_MAX)) return mark_malformed();\n" "case TAG_POSITIVE_SMI: {\n      uint64 value = read_cardinal_64();\n"
mutant decoder-negative-smi-magnitude decoder/message_decoder.render src/messaging.cc "overflow|int64|9223372036854775807" "$DEC_OPTS" \
  "case TAG_NEGATIVE_SMI: {\n      uint64 value = read_cardinal_64();\n      if (value > static_cast<uint64>(INT64_MAX)) return mark_malformed();\n" "case TAG_NEGATIVE_SMI: {\n      uint64 value = read_cardinal_64();\n"
mutant decoder-integer-canonical decoder/message_decoder.render src/messaging.cc "smi_range" "$DEC_OPTS" \
  "  if (Smi::is_valid(value)) return Smi::from(static_cast<word>(value));\n" ""
# decode_external_data (the external message handlers, wave 4): without
# the inline length check the int conversion and the copy's length are
# unbounded (a negative int was a huge memcpy).
mutant decoder-external-inline-length decoder/message_decoder.render src/messaging.cc "pow_nat|truncate|<= 0 n|overflow|underflow" "$DEC_OPTS" \
  "    // As in decode_byte_array: the inline content is in the message.\n    word cardinal = read_cardinal();\n    if (cardinal < 0 || cardinal > remaining()) {\n      mark_malformed();\n      return false;\n    }\n" "    // As in decode_byte_array: the inline content is in the message.\n    word cardinal = read_cardinal();\n"
mutant decoder-external-string-length decoder/message_decoder.render src/messaging.cc "pow_nat|truncate|<= 0 n|overflow|underflow" "$DEC_OPTS" \
  "  } else if (tag == TAG_STRING_INLINE) {\n    word cardinal = read_cardinal();\n    if (cardinal < 0 || cardinal > remaining()) {\n      mark_malformed();\n      return false;\n    }\n" "  } else if (tag == TAG_STRING_INLINE) {\n    word cardinal = read_cardinal();\n"
# The externals table: one entry too many is written past it.
mutant decoder-externals-bound decoder/message_decoder.render src/messaging.cc "pointers|intptrs|No matching|<= 8|index" "$DEC_OPTS" \
  "if (index >= ARRAY_SIZE(externals_)) {" "if (index > ARRAY_SIZE(externals_)) {"

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

# bitmap byte_zap. `-allow_dead_code`: on ILP32 the int argument's round
# trip check is dead (int is a word).
entry byte-zap              pass "" prims/byte_zap.gen.c -allow_dead_code -prover z3v4.5
# One byte past the destination: the memset fails.
mutant byte-zap-past-end prims/byte_zap.render src/primitive_bitmap.cc "uchars|No matching" "-allow_dead_code -prover z3v4.5" \
  "  memset(bytes.address(), value, bytes.length());" "  memset(bytes.address(), value, bytes.length() + 1);"

# time_info and its calendar (red-team round 4). `-allow_dead_code`: the
# time_t round trip check of os_localtime is dead on LP64; UNREACHABLE.
TI_OPTS="-allow_dead_code -prover z3v4.5"
entry time-info             pass "" prims/time_info.gen.c -allow_dead_code -prover z3v4.5
# The fix reverted: `days * SECONDS_PER_DAY` overflows near INT64_MIN.
mutant time-info-seconds-of-day prims/time_info.render src/primitive_core.cc "overflow|underflow" "$TI_OPTS" \
  "int seconds_of_day = static_cast<int>(floor_mod(timestamp, SECONDS_PER_DAY));" "int seconds_of_day = static_cast<int>(timestamp - days * SECONDS_PER_DAY);"
# local_fields without its year check: the shift into the equivalent year
# overflows (the year is unbounded).
mutant time-info-local-year prims/time_info.render src/primitive_core.cc "overflow|underflow|1000000000000000" "$TI_OPTS" \
  "  if (!Smi::is_valid32(utc.year)) return false;\n" "" \
  "  if (!Smi::is_valid32(utc.year)) /*@ open tm_fields(&tm); @*/ return false;\n" ""
# The primitive without its year check: the year is not a smi (on ILP32
# not even a word: the conversion fails first).
mutant time-info-year-smi prims/time_info.render src/primitive_core.cc "smi_range|overflow|underflow" "$TI_OPTS" \
  "  if (!Smi::is_valid32(fields.year)) FAIL(OUT_OF_RANGE);\n" ""

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
    rust/view_accessors.rs > "$ACXX_WORK/logs/view_accessors_neg.rs"
  rust_entry_run rust-view-index-at-length fail "$ACXX_WORK/logs/view_accessors_neg.rs" || f=$((f + $?))
  # The like-for-like trial (README, "The Rust raw-memory layer"): of the
  # five accessors, class_id and class_tag stop VeriFast's Rust front end
  # ("Todo: BinOp::Shr"); the other three verify.
  sed '/pub unsafe fn class_id/,/^    }$/d' rust/view_trial.rs | sed '/pub unsafe fn class_tag/,/^    }$/d' \
    > "$ACXX_WORK/logs/view_trial_noshift.rs"
  rust_entry_run rust-trial-three pass "$ACXX_WORK/logs/view_trial_noshift.rs" || f=$((f + $?))
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

# The second phase.
render_status=0
if [ -n "$render_pid" ]; then
  wait "$render_pid"
  render_status=$?
fi
for d in "${deferred[@]}"; do
  eval "spawn $d"
done

for i in "${!pids[@]}"; do
  if [ "${pids[$i]}" = "$render_pid" ]; then
    s=$render_status
  else
    wait "${pids[$i]}"
    s=$?
  fi
  [ $s -ne 0 ] && failures=$((failures + s))
  cat "$JOBS/$i.log"
done
echo "failures: $failures"
exit $((failures > 0))
