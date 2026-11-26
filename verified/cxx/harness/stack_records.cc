// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "objects_inline.h"
#undef private

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  // Format 3 (verified/spec/format/23-format3-try.md): the frame top is a
  // plain header word; no finally records follow the frame records.
  // The accessors only need the header. The logical stack length bounds
  // the positions exactly as it does for a full stack at a GC point.
  uword header[Stack::HEADER_SIZE / WORD_SIZE];
  auto* stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(header)));
  word length = nondet_word();
  word frame = nondet_word();
  word bci = nondet_word();
  CXXV_ASSUME(0 <= length && length <= Stack::max_length());
  CXXV_ASSUME(0 <= frame && frame <= length);
  unsigned probe = nondet_uint();
  CXXV_ASSUME(probe < Stack::HEADER_SIZE / WORD_SIZE);
  uword prior = nondet_ulong();
  header[probe] = prior;
  if (nondet_bool()) {
    stack->v2_set_records(frame, bci);
  } else {
    // A new task's frame top (prepare_process_v2) next to a bci set apart.
    stack->v2_set_bci(bci);
    stack->v2_set_frame_top(frame);
  }
  CXXV_ASSERT(stack->v2_frame_top() == frame && stack->v2_frame_top_word() == static_cast<uword>(frame) &&
              stack->v2_bci() == bci,
              "recover the complete format-2 record state from its two header words");
  if (probe != Stack::TRY_TOP_OFFSET / WORD_SIZE && probe != Stack::PENDING_STACK_CHECK_METHOD_OFFSET / WORD_SIZE) {
    CXXV_ASSERT(header[probe] == prior, "preserve every other header and guard word");
  }
}
