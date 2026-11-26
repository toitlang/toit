// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "interpreter_v2.h"
#include "process_group.h"
#include "objects_inline.h"
#undef private
#include "v2_method_table.cc"
#include "interpreter_v2.cc"

using namespace toit;

extern Process caller;
extern ProcessGroup group;
extern Program image;
GcMetadata GcMetadata::singleton_;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  caller.group_ = &group;
  caller.program_ = &image;
  uint32 records[] = {nondet_uint(), nondet_uint()};
  V2MethodTable table(records, 2, nullptr, 0, false);
  group.v2_methods_ = &table;
  int method_index = nondet_int();
  int dispatch[] = {method_index};
  image.dispatch_table = List<int>(dispatch, 1);
  int dispatch_index = nondet_int();
  bool valid_entry = dispatch_index == 0 && method_index >= 0 && method_index < 2;
  image.entry_point_indexes_[Program::entry_task_INDEX] = dispatch_index;
  uword task_header = 2 * TASK_TAG;
  auto* task = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(&task_header)));
  uword false_header = 0;
  auto* false_value = HeapObject::from_address(reinterpret_cast<uword>(&false_header));
  image.roots_[Program::false_object_INDEX] = false_value;

  const word f = Stack::V2_FRAME_WORDS;
  const word h = Stack::HEADER_SIZE / WORD_SIZE;
  word frames = nondet_word();
  CXXV_ASSUME(frames >= 0 && frames <= (Stack::V2_MAX_LENGTH - 1) / f);
  word frame_top = frames * f;
  uword source[h + frame_top + 1];
  auto* from = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(source)));
  source[0] = 2 * STACK_TAG;
  source[Stack::LENGTH_OFFSET / WORD_SIZE] = frame_top + 1;
  source[Stack::TRY_TOP_OFFSET / WORD_SIZE] = static_cast<uword>(frame_top);
  word bci = nondet_uint() >> 1;
  from->v2_set_bci(bci);
  word method = nondet_uint() >> 1;
  if (frames != 0) from->v2_word_at_put(frame_top - f + Stack::V2_FRAME_METHOD, method);

  word length = nondet_word();
  CXXV_ASSUME(length >= 1 && length < Stack::V2_MAX_LENGTH);
  uword target[h + length];
  target[0] = 2 * STACK_TAG;
  target[Stack::LENGTH_OFFSET / WORD_SIZE] = length;
  auto* to = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(target)));
  word top = nondet_word();
  CXXV_ASSUME(top >= 0 && top <= length);
  to->v2_set_top(top);
  to->v2_set_records(0, 0);
  word witness = nondet_word();
  CXXV_ASSUME(witness >= 0 && witness < length);
  uword original = nondet_ulong();
  to->v2_word_at_put(witness, original);
  uint8 cards[3] = {};
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(cards + 1) -
      (reinterpret_cast<uword>(to) >> GcMetadata::CARD_SIZE_LOG_2);

  bool started = v2_start_task(&caller, from, to, task);
  bool can_start = valid_entry && frames > 0 && top == length - 1 &&
                   length >= 3 + 2 * f + Stack::V2_STACK_RESERVE;
  CXXV_ASSERT(started == can_start, "start exactly when the entry, caller frame and target stack are ready");
  CXXV_ASSERT(cards[0] == 0 && cards[2] == 0 && cards[1] == (started ? GcMetadata::NEW_SPACE_POINTERS : 0),
              "dirty only the target card on success");
  CXXV_ASSERT(to->length() == length && to->top() == (started ? length - 3 : top) &&
              to->v2_frame_top() == (started ? 2 * f : 0) && to->v2_frame_top_word() == static_cast<uword>(to->v2_frame_top()) &&
              to->v2_bci() == (started ? bci : 0), "install two frames, three slots and the caller bci only on success");
  uword expected = original;
  if (started) {
    const uword entry = records[method_index] >> V2_RECORD_ENTRY_SHIFT;
    if (witness == length - 2) expected = reinterpret_cast<uword>(task);
    if (witness == length - 3) expected = reinterpret_cast<uword>(false_value);
    if (witness == Stack::V2_FRAME_METHOD) expected = method_index;
    if (witness == Stack::V2_FRAME_RET) expected = entry;
    if (witness == Stack::V2_FRAME_BASE || witness == Stack::V2_FRAME_HANDLER) expected = 0;
    if (witness == f + Stack::V2_FRAME_METHOD) expected = method;
    if (witness == f + Stack::V2_FRAME_RET) expected = entry + 1;
    if (witness == f + Stack::V2_FRAME_BASE) expected = 1;
    if (witness == f + Stack::V2_FRAME_HANDLER) expected = 0;
  }
  CXXV_ASSERT(to->v2_word_at(witness) == expected, "exact frame and slot contents, preserving the code and other words");
}
