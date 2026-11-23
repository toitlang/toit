// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "objects_inline.h"
#undef private

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  static_assert(Stack::V2_FIN_WORDS == 5, "record size in the FFI stack contract");
  // Record accessors only need the header. The logical stack length bounds
  // the positions exactly as it does for a full stack at a GC point.
  uword header[Stack::HEADER_SIZE / WORD_SIZE];
  auto* stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(header)));
  word length = nondet_word();
  word frame = nondet_word();
  word fin = nondet_word();
  word bci = nondet_word();
  CXXV_ASSUME(0 <= length && length <= Stack::max_length());
  CXXV_ASSUME(0 <= frame && frame <= length && 0 <= fin && fin <= (length - frame) / Stack::V2_FIN_WORDS);
  unsigned probe = nondet_uint();
  CXXV_ASSUME(probe < Stack::HEADER_SIZE / WORD_SIZE);
  uword prior = nondet_ulong();
  header[probe] = prior;
  stack->v2_set_records(frame, fin, bci);
  word end = frame + Stack::V2_FIN_WORDS * fin;
  CXXV_ASSERT(stack->v2_record_top() == end && stack->v2_frame_top() == frame &&
              stack->v2_fin_count() == fin && stack->v2_bci() == bci,
              "recover the complete format-2 record state from its two header words");
  if (probe != Stack::TRY_TOP_OFFSET / WORD_SIZE && probe != Stack::PENDING_STACK_CHECK_METHOD_OFFSET / WORD_SIZE) {
    CXXV_ASSERT(header[probe] == prior, "preserve every other header and guard word");
  }
}
