// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "heap.cc"
#include "objects.cc"
#undef protected
#undef private

using namespace toit;
extern Program image;
extern Process process;

void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "the supplied task graph has valid headers and fields");
  abort();
}

class ForwardTask : public RootCallback {
 public:
  Task* old_task;
  Task* current_task;
  unsigned calls = 0;

  void do_roots(Object** roots, word count) override {
    if (calls == 0) {
      CXXV_ASSERT(count == 1 && *roots == old_task, "the first root holds the original task");
      *roots = current_task;
    } else {
      CXXV_ASSERT(calls == 1 && count == 0, "the empty globals range completes this process");
    }
    ++calls;
  }
};

class ForwardStack : public RootCallback {
 public:
  Stack* old_stack;
  Stack* current_stack;
  unsigned calls = 0;

  void do_roots(Object** roots, word count) override {
    CXXV_ASSERT(calls == 0 && count == 2, "visit both task fields together");
    CXXV_ASSERT(roots[0] == old_stack && is_smi(roots[1]), "visit the copied stack reference and scalar ID");
    roots[0] = current_stack;
    ++calls;
  }
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  auto* heap = process.object_heap();
  new (heap) ObjectHeap(&image, &process, nullptr, nullptr, nullptr);
  image.global_variables.length_ = 0;
  uint16 task_class = Program::compute_class_bits(TASK_TAG, 3 * WORD_SIZE);
  image.class_bits = List<uint16>(&task_class, 1);
  uword stack_headers[2] = {2 * STACK_TAG, 2 * STACK_TAG};
  auto* old_stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(stack_headers)));
  auto* moved_stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(stack_headers + 1)));
  Stack* current_stack = nondet_bool() ? old_stack : moved_stack;
  word task_id = nondet_word();
  CXXV_ASSUME(Smi::is_valid(task_id));
  Smi* id = Smi::from(task_id);
  Object* task_words[] = {nullptr, old_stack, id, nullptr, old_stack, id};
  auto* old_task = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(task_words)));
  auto* moved_task = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(task_words + 3)));
  old_task->_set_header(Smi::zero(), TASK_TAG);
  moved_task->_set_header(Smi::zero(), TASK_TAG);
  Task* current_task = nondet_bool() ? old_task : moved_task;
  heap->task_ = old_task;

  ForwardTask visitor;
  visitor.old_task = old_task;
  visitor.current_task = current_task;
  heap->iterate_roots(&visitor);
  CXXV_ASSERT(visitor.calls == 2, "visit the task and globals");
  CXXV_ASSERT(process.task() == current_task, "reload the task selected by the process-root visitor");
  ForwardStack fields;
  fields.old_stack = old_stack;
  fields.current_stack = current_stack;
  process.task()->roots_do(&image, &fields);
  CXXV_ASSERT(fields.calls == 1 && process.task()->stack() == current_stack &&
              process.task()->id() == task_id, "reload the forwarded stack and preserve the task ID");
  if (old_task != current_task) {
    CXXV_ASSERT(old_task->stack() == old_stack, "only the relocated task receives the stack update");
  }
}
