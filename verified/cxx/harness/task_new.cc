// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "objects_inline.h"
#include "scheduler.h"
#undef private
using std::fpclassify;
#include "primitive_core.cc"

using namespace toit;

extern Process caller;
extern Program image;
extern SchedulerThread thread;
GcMetadata GcMetadata::singleton_;
static Object* code;
static Task* running;
static Task* fresh;
static bool allocation_failed;
static unsigned phase;
static uint8* entry_bytes;

Task* ObjectHeap::allocate_task() {
  CXXV_ASSERT(this == caller.object_heap() && phase == 0, "allocate one task on the calling heap");
  ++phase;
  return allocation_failed ? nullptr : fresh;
}

void Interpreter::store_stack(Object** sp, Method pending) {
  CXXV_ASSERT(this == thread.interpreter() && !pending.is_valid() && sp == nullptr &&
              ((phase == 1 && caller.task() == running) || (phase == 4 && caller.task() == fresh)),
              "save the caller before switching and the new task after preparation");
  ++phase;
}

Object** Interpreter::load_stack(Method* pending) {
  CXXV_ASSERT(this == thread.interpreter() && pending == nullptr &&
              ((phase == 2 && caller.task() == fresh) || (phase == 5 && caller.task() == running)),
              "load the new task and then restore the caller");
  ++phase;
  return nullptr;
}

void Interpreter::prepare_task(Method entry, Instance* supplied) {
  CXXV_ASSERT(phase == 3 && caller.task() == fresh, "prepare the newly loaded task");
  CXXV_ASSERT(this == thread.interpreter(), "prepare on the caller's interpreter");
  CXXV_ASSERT(entry.header_bcp() == entry_bytes, "prepare at the dispatch entry");
  CXXV_ASSERT(reinterpret_cast<uword>(supplied) == reinterpret_cast<uword>(code), "prepare with the original tagged code");
  ++phase;
}

void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "a loaded task entry is valid");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uint8 bytecodes[16] = {'T', 'B', 'C', '2'};
  bool format2 = nondet_bool();
  if (!format2) bytecodes[0] = 0;
  image.bytecodes = List<uint8>(bytecodes, sizeof(bytecodes));
  int dispatch[] = {4, 8};
  bool second_entry = nondet_bool();
  entry_bytes = bytecodes + (second_entry ? 8 : 4);
  image.dispatch_table = List<int>(dispatch, 2);
  image.entry_point_indexes_[Program::entry_task_INDEX] = second_entry ? 1 : 0;
  caller.program_ = &image;
  caller.scheduler_thread_ = &thread;
  uword old_task[3] = {2 * TASK_TAG, 0, 0};
  uword new_task[3] = {2 * TASK_TAG, 0, 0};
  running = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(old_task)));
  fresh = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(new_task)));
  caller.object_heap()->task_ = running;
  uword epoch = nondet_ulong();
  caller.object_heap()->v2_epoch_ = epoch;
  const word length = Stack::initial_length();
  uword stack_words[Stack::HEADER_SIZE / WORD_SIZE + length];
  stack_words[0] = 2 * STACK_TAG;
  stack_words[Stack::LENGTH_OFFSET / WORD_SIZE] = length;
  auto* stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(stack_words)));
  new_task[1] = reinterpret_cast<uword>(stack);
  uint8 card = 0;
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(&card) -
      (reinterpret_cast<uword>(stack) >> GcMetadata::CARD_SIZE_LOG_2);
  bool heap = nondet_bool();
  uword header = nondet_ulong() & ~uword{1};
  code = heap ? static_cast<Object*>(HeapObject::from_address(reinterpret_cast<uword>(&header)))
              : reinterpret_cast<Object*>(nondet_ulong() & ~uword{1});
  bool valid = heap && ((header >> 1) & 15) == INSTANCE_TAG;
  allocation_failed = nondet_bool();
  Object* frame[] = {code};
  Object* result = primitive_task_new(&caller, frame);
  int error = !valid ? Program::WRONG_OBJECT_TYPE_INDEX : allocation_failed ? Program::ALLOCATION_FAILED_INDEX : -1;
  Object* expected = error < 0 ? static_cast<Object*>(fresh) :
      reinterpret_cast<Object*>((static_cast<uword>(error) << Error::ERROR_SHIFT) | Error::ERROR_TAG);
  CXXV_ASSERT(result == expected && frame[0] == code && caller.task() == running, "return the exact task or error with the caller restored");
  CXXV_ASSERT(phase == (!valid ? 0u : error >= 0 || format2 ? 1u : 6u), "execute only the required allocation and interpreter calls");
  CXXV_ASSERT(caller.object_heap()->v2_epoch_ == epoch + (error < 0 && !format2 ? 2u : 0u), "switch the active task only for legacy preparation");
  if (error < 0 && format2) {
    CXXV_ASSERT(stack->top() == length - 1 && *stack->v2_slot_address(0) == code &&
                stack->v2_records_word() == 0 && stack->v2_bci() == 0 && card == GcMetadata::NEW_SPACE_POINTERS,
                "return an unstarted format-2 task with the original code and no frames");
  } else {
    CXXV_ASSERT(card == 0, "no format-2 initialization on other paths");
  }
}
