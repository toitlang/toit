// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "interpreter_v2.h"
#include "objects_inline.h"
#include "process_group.h"
#include "scheduler.h"
#undef private
using std::fpclassify;
#include "primitive_core.cc"
#include "v2_method_table.cc"
#include "interpreter_v2.cc"

using namespace toit;

extern Process caller;
extern ProcessGroup group;
extern Program image;
extern SchedulerThread thread;
GcMetadata GcMetadata::singleton_;
static Task* running;
static Task* target;
static unsigned calls;

void Interpreter::store_stack(Object** sp, Method pending) {
  CXXV_ASSERT(calls == 0 && caller.task() == running && this == thread.interpreter() &&
              sp == nullptr && !pending.is_valid(), "legacy transfer saves the running task before switching");
  calls++;
}

Object** Interpreter::load_stack(Method* pending) {
  CXXV_ASSERT(calls == 1 && caller.task() == target && this == thread.interpreter() && pending == nullptr,
              "legacy transfer restores the target after switching");
  calls++;
  return nullptr;
}

void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "a valid transfer never takes the fatal path");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  caller.group_ = &group;
  caller.program_ = &image;
  caller.scheduler_thread_ = &thread;
  bool format2 = nondet_bool();
  uint8 bytes[] = {'T', 'B', 'C', '3'};
  if (!format2) bytes[0] = 0;
  image.bytecodes = List<uint8>(bytes, 4);
  uint32 record = nondet_uint();
  V2MethodTable table(&record, 1, bytes, 4, false);
  group.v2_methods_ = &table;
  int dispatch[] = {0};
  image.dispatch_table = List<int>(dispatch, 1);
  image.entry_point_indexes_[Program::entry_task_INDEX] = 0;
  uword false_header = 0, true_header = 0;
  caller.false_object_ = HeapObject::from_address(reinterpret_cast<uword>(&false_header));
  caller.true_object_ = HeapObject::from_address(reinterpret_cast<uword>(&true_header));
  image.roots_[Program::false_object_INDEX] = caller.false_object_;
  image.roots_[Program::true_object_INDEX] = caller.true_object_;

  // Equal offsets in consecutive cards give the two stacks distinct barrier bytes.
  const word stride = GcMetadata::CARD_SIZE / WORD_SIZE;
  const word length = stride - Stack::HEADER_SIZE / WORD_SIZE;
  static_assert(length >= 3 + 2 * Stack::V2_FRAME_WORDS + Stack::V2_STACK_RESERVE, "enough room to start");
  uword stacks[2 * stride];
  auto* from = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(stacks)));
  auto* to = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(stacks + stride)));
  stacks[0] = stacks[stride] = 2 * STACK_TAG;
  stacks[Stack::LENGTH_OFFSET / WORD_SIZE] = stacks[stride + Stack::LENGTH_OFFSET / WORD_SIZE] = length;
  from->v2_set_records(Stack::V2_FRAME_WORDS, 4);
  from->v2_word_at_put(Stack::V2_FRAME_METHOD, 0);
  bool unstarted = nondet_bool();
  to->v2_set_records(unstarted ? 0 : Stack::V2_FRAME_WORDS, 7);
  to->v2_set_top(length - 1);
  uint8 cards[2] = {};
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(cards) -
      (reinterpret_cast<uword>(from) >> GcMetadata::CARD_SIZE_LOG_2);
  uword old_words[] = {2 * TASK_TAG, reinterpret_cast<uword>(from), 0};
  running = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(old_words)));
  bool live = nondet_bool();
  uword target_stack = live ? reinterpret_cast<uword>(to) : 0;
  uword new_words[] = {2 * TASK_TAG, target_stack, 0};
  target = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(new_words)));
  caller.object_heap()->task_ = running;
  uword epoch = nondet_ulong();
  caller.object_heap()->v2_epoch_ = epoch;

  bool same = nondet_bool(), valid_task = nondet_bool(), valid_bool = nondet_bool(), detach = nondet_bool();
  Object* selected = same ? running : target;
  Object* invalid_task = nondet_bool() ? static_cast<Object*>(caller.false_object_) : Smi::zero();
  Object* args[] = {valid_bool ? image.boolean(detach) : Smi::zero(), valid_task ? selected : invalid_task};
  Object* result = primitive_task_transfer(&caller, args + 1);
  bool wrong = !valid_task || !valid_bool;
  bool dead = !wrong && !same && !live;
  bool switched = !wrong && !same && live;
  bool started = switched && format2 && unstarted;
  uword expected = reinterpret_cast<uword>(selected) | Error::ERROR_TAG;
  if (wrong || dead) {
    uword index = wrong ? Program::WRONG_OBJECT_TYPE_INDEX : Program::ERROR_INDEX;
    expected = (index << Error::ERROR_SHIFT) | Error::ERROR_TAG;
  }
  CXXV_ASSERT(reinterpret_cast<uword>(result) == expected, "return the marked task or the precise type or dead-task error");
  CXXV_ASSERT(caller.task() == (switched ? target : running) && caller.object_heap()->v2_epoch_ == epoch + switched,
              "switch current task and advance the epoch exactly once on transfer");
  CXXV_ASSERT(old_words[1] == (switched && detach ? 0 : reinterpret_cast<uword>(from)) && new_words[1] == target_stack,
              "detach only the outgoing task and only on request");
  CXXV_ASSERT(calls == (switched && !format2 ? 2u : 0u), "only legacy switches call the interpreter stack operations");
  CXXV_ASSERT(cards[0] == (switched && format2 ? GcMetadata::NEW_SPACE_POINTERS : 0) &&
              cards[1] == (started ? GcMetadata::NEW_SPACE_POINTERS : 0), "dirty the saved stack and any newly started stack");
  CXXV_ASSERT(to->v2_frame_top() == (started ? 2 * Stack::V2_FRAME_WORDS : unstarted ? 0 : Stack::V2_FRAME_WORDS) &&
              to->top() == (started ? length - 3 : length - 1) && to->v2_bci() == (started ? 4 : 7),
              "build frames only for a first format-2 transfer");
}
