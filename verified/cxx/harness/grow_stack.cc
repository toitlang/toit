// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// Pilot target (c): toit_v2_grow_stack (src/interpreter_v2.cc) with
// Stack::v2_copy_to (src/objects_runtime.cc), the C++ side of the Verus
// leaf contract step::gc_grow_stack (verified/core/src/step.rs):
//
//   requires reloaded(m, g).refines(p)
//   ensures  reloaded(m', g).refines(p),
//            r == V2_OK ==> top' - rtop' >= needed
//
// The real interpreter_v2.cc and objects_runtime.cc are compiled
// unmodified. What is modelled instead of compiled (all of it group (3),
// trusted by decision):
//  * raw reservation (TwoSpaceHeap::allocate): fails or supplies fresh
//    storage. The native ObjectHeap::allocate_stack sets the header,
//    initializes the guards and fills the entire format-2 payload;
//  * the GC (Scheduler::gc, no body here): moves nothing. The function
//    re-reads the task's stack after each GC, which this model cannot test;
//  * the card-marking write barrier (GcMetadata::insert_into_remembered_set,
//    an address computation into a side table that an object-based memory
//    model cannot express): replaced by explicit specializations that
//    count the marks;
//  * TOIT_V2_VALIDATE is unset (getenv returns null).
//
// "refines" is reduced to the stack facts the C++ reads: the records occupy
// [0, record_top), the object stack [top, length), record_top <= top <=
// length <= Stack::max_length(), frame_top <= record_top with whole
// finally records between them.
//
// Properties, for every such stack (any length up to max_length) and every
// `needed` up to CXXV_NEEDED_MAX:
//  P1 memory safety and no UB (both memcpy calls of v2_copy_to in bounds);
//  P2 the result is OK, STACK_OVERFLOW or OUT_OF_MEMORY;
//  P3 OK ==> the task's new stack has top - record_top >= needed (the
//     Verus ensures), the same records, frame top, finally count and bci,
//     and the same object-stack slots at the same positions from the end
//     (the slot positions the core uses), so the abstract state is the
//     same ("refines" again);
//  P4 not OK ==> the task keeps its stack, unchanged in length and top.

#define RAW
#define CXXV_NO_ODDBALLS  // Fewer heap objects: cheaper pointer resolution.
#define private public
#define protected public
#include "prelude.h"
#include "third_party/dartino/gc_metadata.h"

namespace toit {
static int cxxv_card_marks = 0;
template <> inline void GcMetadata::insert_into_remembered_set<Stack*>(Stack* address) { cxxv_card_marks++; }
template <> inline void GcMetadata::insert_into_remembered_set<Instance*>(Instance* address) { cxxv_card_marks++; }
template <> inline void GcMetadata::insert_into_remembered_set<Array*>(Array* address) { cxxv_card_marks++; }
}  // namespace toit

#include "interpreter_v2.cc"
#include "heap.cc"
#include "objects.cc"
// Stack::v2_copy_to, extracted verbatim from src/objects_runtime.cc by
// verified/cxx/esbmc.sh (ESBMC 8.6 crashes on the whole file: tool defect T3).
namespace toit {
#include "v2_copy_to.inc"
}  // namespace toit
#undef private
#undef protected

#include "constants.h"
#include "heap_model.h"

using namespace toit;

#ifndef CXXV_NEEDED_MAX
#define CXXV_NEEDED_MAX 0x10000
#endif

extern "C" char* getenv(const char* name) { return null; }

namespace toit {
HeapObject* TwoSpaceHeap::allocate(uword bytes) {
  if (nondet_bool()) return nullptr;
  return cxxv::raw_object(bytes);
}
}  // namespace toit

int main() {
  cxxv::cxxv_constants();
  cxxv::World world;
  cxxv::make_world(&world);
  Process* process = world.process;
  *const_cast<Program**>(&process->object_heap_.program_) = world.program;
  uint8 bytecodes[] = {'T', 'B', 'C', '2'};
  world.program->bytecodes = List<uint8>(bytecodes, 4);
  world.class_bits[Program::stack_class_id_INDEX] = Program::compute_class_bits(STACK_TAG, 0);

  // The VM and scheduler the GC path dereferences (fields unconstrained).
  VM* vm = static_cast<VM*>(malloc(sizeof(VM)));
  CXXV_ASSUME(vm != null);
  vm->scheduler_ = static_cast<Scheduler*>(malloc(sizeof(Scheduler)));
  CXXV_ASSUME(vm->scheduler_ != null);
  VM::current_ = vm;

  // The current task's stack, as the core leaves it before the call.
  word length = nondet_word();
  CXXV_ASSUME(0 < length && length <= Stack::max_length());
#ifdef CXXV_MAX_LENGTH
  CXXV_ASSUME(length <= CXXV_MAX_LENGTH);
#endif
  HeapObject* raw = cxxv::raw_object(Stack::allocation_size(length));
  cxxv::set_header(raw, Program::stack_class_id_INDEX, STACK_TAG);
  Stack* stack = static_cast<Stack*>(raw);
  stack->_set_length(length);
  // At a GC point StackMem owns initialized words throughout the old array.
  for (word i = 0; i < length; ++i) stack->v2_word_at_put(i, nondet_ulong());
  word top = nondet_word();
  word frame_top = nondet_word();
  word fin_count = nondet_word();
  word bci = nondet_word();
  CXXV_ASSUME(0 <= frame_top && frame_top <= length && 0 <= fin_count && fin_count <= length);
  word record_top = frame_top + Stack::V2_FIN_WORDS * fin_count;
  CXXV_ASSUME(record_top <= top && top <= length);
  stack->_set_top(top);
  stack->v2_set_records(frame_top, fin_count, bci);

  // The task (TASK_TAG instance with the stack and id fields).
  HeapObject* raw_task = cxxv::raw_object(Instance::HEADER_SIZE + 2 * WORD_SIZE);
  cxxv::set_header(raw_task, Program::task_class_id_INDEX, TASK_TAG);
  Task* task = static_cast<Task*>(raw_task);
  task->at_put_no_write_barrier(Task::STACK_INDEX, stack);
  task->at_put_no_write_barrier(Task::ID_INDEX, Smi::from(1));
  process->object_heap_.task_ = task;

  word needed = nondet_word();
  CXXV_ASSUME(0 <= needed && needed <= CXXV_NEEDED_MAX);

  // One record word and one object-stack slot to follow through the copy.
  word record_index = nondet_word();
  word slot_position = nondet_word();  // Position from the end, as the core.
  uword record_value = 0;
  uword slot_value = 0;
  bool has_record = 0 <= record_index && record_index < record_top;
  bool has_slot = 0 <= slot_position && slot_position < length - top;
  if (has_record) record_value = stack->v2_word_at(record_index);
  if (has_slot) slot_value = stack->v2_word_at(length - 1 - slot_position);

  uword r = toit_v2_grow_stack(process, needed);

  CXXV_ASSERT(r == TOIT_V2_OK || r == TOIT_V2_STACK_OVERFLOW || r == TOIT_V2_OUT_OF_MEMORY, "P2");
  Stack* now = process->task()->stack();
  if (r == TOIT_V2_OK) {
    CXXV_ASSERT(now->top() - now->v2_record_top() >= needed, "P3: needed words free (Verus ensures)");
    CXXV_ASSERT(now->length() - now->top() == length - top, "P3: same object-stack height");
    CXXV_ASSERT(now->v2_frame_top() == frame_top, "P3: same frame top");
    CXXV_ASSERT(now->v2_fin_count() == fin_count, "P3: same finally records");
    CXXV_ASSERT(now->v2_bci() == bci, "P3: same bci");
    word gap_index = nondet_word();
    if (now->v2_record_top() <= gap_index && gap_index < now->top()) {
      CXXV_ASSERT(now->v2_word_at(gap_index) == 0, "P3: the unused gap retains the allocator's tagged zero");
    }
    if (has_record) CXXV_ASSERT(now->v2_word_at(record_index) == record_value, "P3: records copied");
    if (has_slot) {
      CXXV_ASSERT(now->v2_word_at(now->length() - 1 - slot_position) == slot_value, "P3: slots copied");
    }
  } else {
    CXXV_ASSERT(now == stack && now->length() == length && now->top() == top, "P4: stack unchanged");
  }
  return 0;
}
