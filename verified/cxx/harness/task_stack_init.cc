// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "objects_inline.h"
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;
extern Process caller;

static void check_task_ids() {
  uint32 next = nondet_uint();
  caller.next_task_id_ = next;
  uint32 limit = sizeof(word) == 4 ? (UINT32_C(1) << 30) - 1 : INT32_MAX;
  CXXV_ASSERT(caller.has_task_id() == (next <= limit), "admit exactly representable nonnegative task ids");
  if (caller.has_task_id()) {
    int id = caller.next_task_id();
    CXXV_ASSERT(id >= 0 && static_cast<uint32>(id) == next && Smi::value(Smi::from(id)) == id,
                "assigned task id is exact as both a profiler int and a tagged integer");
    CXXV_ASSERT(caller.next_task_id_ == next + 1 && caller.has_task_id() == (next < limit),
                "advance exactly once and stop after the final representable id");
  }
}

static void check_initial_stack() {
  word length = nondet_word();
  CXXV_ASSUME(length >= Stack::V2_FRAME_WORDS + 1 && length < Stack::V2_MAX_LENGTH);
  uword words[Stack::HEADER_SIZE / WORD_SIZE + length];
  auto* stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(words)));
  words[0] = 2 * STACK_TAG;
  words[Stack::LENGTH_OFFSET / WORD_SIZE] = length;
  uword code_header = 2 * INSTANCE_TAG;
  Object* code = HeapObject::from_address(reinterpret_cast<uword>(&code_header));
  uint8 cards[3] = {0, 0, 0};
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(cards + 1) -
      (reinterpret_cast<uword>(stack) >> GcMetadata::CARD_SIZE_LOG_2);
  word witness = nondet_word();
  CXXV_ASSUME(witness >= 0 && witness < length - 1);
  uword original = nondet_ulong();
  words[Stack::HEADER_SIZE / WORD_SIZE + witness] = original;

  stack->v2_initialize_new_task(code);
  CXXV_ASSERT(stack->length() == length && stack->top() == length - 1 &&
              stack->v2_frame_top() == 0 && stack->v2_record_top() == 0 && stack->v2_bci() == 0,
              "new task starts with one active slot, zero frames, zero finally records and bytecode index zero");
  CXXV_ASSERT(*stack->v2_slot_address(0) == code && words[Stack::HEADER_SIZE / WORD_SIZE + witness] == original,
              "put the original code in the sole active slot and preserve every other payload word");
  CXXV_ASSERT(cards[0] == 0 && cards[1] == GcMetadata::NEW_SPACE_POINTERS && cards[2] == 0,
              "dirty the new stack's card after installing its object reference");
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  if (nondet_bool()) check_task_ids();
  else check_initial_stack();
}
