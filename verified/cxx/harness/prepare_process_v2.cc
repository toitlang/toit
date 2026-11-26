// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "interpreter.h"
#include "interpreter_v2.h"
#include "process_group.h"
#include "objects_inline.h"
#undef private
#include "v2_method_table.cc"
#include "interpreter_v2.cc"

using namespace toit;

extern Process child;
extern Interpreter interpreter;
extern ProcessGroup group;
extern Program image;
GcMetadata GcMetadata::singleton_;

void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "a resolved entry and sufficient stack space permit startup");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  interpreter.process_ = &child;
  child.group_ = &group;
  child.program_ = &image;
  uint8 spawn_code;
  bool spawned = nondet_bool();
  child.spawn_method_ = spawned ? Method(&spawn_code) : Method::invalid();
  // The literal parser bounds the method count and wf_program2 bounds
  // dispatch. Materialize only the two entries that startup can select.
  int methods = nondet_int(), slots = nondet_int();
  CXXV_ASSUME(methods > 0 && methods < 0x1000000 && slots > 0 && slots < 0x10000000);
  int main_slot = nondet_int(), spawn_slot = nondet_int();
  CXXV_ASSUME(main_slot >= 0 && main_slot < slots && spawn_slot >= 0 && spawn_slot < slots);
  int main_method = nondet_int(), spawn_method = nondet_int();
  CXXV_ASSUME(main_method >= 0 && main_method < methods && spawn_method >= 0 && spawn_method < methods);
  int dispatch[slots];
  dispatch[main_slot] = main_method;
  dispatch[spawn_slot] = spawn_method;
  uint32 records[methods];
  records[main_method] = nondet_uint();
  records[spawn_method] = nondet_uint();
  V2MethodTable table(records, methods, nullptr, 0, false);
  group.v2_methods_ = &table;
  image.dispatch_table = List<int>(dispatch, slots);
  image.entry_point_indexes_[Program::entry_main_INDEX] = main_slot;
  // A main launch can use a program whose spawn entry was tree-shaken.
  image.entry_point_indexes_[Program::entry_spawn_INDEX] = (spawned || nondet_bool()) ? spawn_slot : -1;
  int method = dispatch[spawned ? spawn_slot : main_slot];
  word bci = records[method] >> V2_RECORD_ENTRY_SHIFT;

  word length = nondet_word();
  CXXV_ASSUME(length >= Stack::V2_FRAME_WORDS + 1 && length < Stack::V2_MAX_LENGTH);
  uword words[Stack::HEADER_SIZE / WORD_SIZE + length];
  auto* stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(words)));
  words[0] = 2 * STACK_TAG;
  words[Stack::LENGTH_OFFSET / WORD_SIZE] = length;
  stack->v2_set_records(0, 0);
  stack->v2_set_top(length);
  uword task_words[] = {2 * TASK_TAG, reinterpret_cast<uword>(stack), 0};
  auto* task = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(task_words)));
  child.object_heap()->task_ = task;
  word witness = nondet_word();
  CXXV_ASSUME(witness >= 0 && witness < length);
  uword original = nondet_ulong();
  stack->v2_word_at_put(witness, original);
  uint8 cards[3] = {0, 0, 0};
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(cards + 1) -
      (reinterpret_cast<uword>(stack) >> GcMetadata::CARD_SIZE_LOG_2);

  interpreter.prepare_process_v2();
  CXXV_ASSERT(child.task() == task, "preserve the current task");
  CXXV_ASSERT(task->stack() == stack, "preserve the current task's stack");
  CXXV_ASSERT(stack->length() == length && stack->top() == length - 1, "start with one active object slot");
  CXXV_ASSERT(stack->v2_word_at(length - 1) == reinterpret_cast<uword>(task), "the active slot contains the current task");
  CXXV_ASSERT(stack->v2_frame_top() == Stack::V2_FRAME_WORDS && stack->v2_frame_top_word() == Stack::V2_FRAME_WORDS &&
              stack->v2_bci() == bci, "start at the selected entry with one frame, not a try block");
  uword expected = original;
  if (witness == length - 1) expected = reinterpret_cast<uword>(task);
  if (witness == Stack::V2_FRAME_METHOD) expected = method;
  if (witness == Stack::V2_FRAME_RET) expected = bci;
  if (witness == Stack::V2_FRAME_BASE || witness == Stack::V2_FRAME_HANDLER) expected = 0;
  CXXV_ASSERT(stack->v2_word_at(witness) == expected, "initialize the entry frame and preserve every other payload word");
  CXXV_ASSERT(cards[1] == GcMetadata::NEW_SPACE_POINTERS && cards[0] == 0 && cards[2] == 0,
              "mark the stack card after installing the task reference");
}
