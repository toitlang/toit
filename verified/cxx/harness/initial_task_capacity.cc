// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#ifdef TOIT_FREERTOS
// This arithmetic and bump-allocation check never takes a mutex.
#undef TOIT_FREERTOS
#include "mutex.h"
#define TOIT_FREERTOS
#endif
#define private public
#define protected public
#include "heap.cc"
#include "third_party/dartino/object_memory_copying.cc"
#undef protected
#undef private

using namespace toit;

extern Program image;
extern SemiSpace young;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  int count = nondet_int();
  CXXV_ASSUME(count >= 0 && count < 0x10000000);
  uint16 classes[count + 1];
  image.class_bits = List<uint16>(classes, count);
  word raw = nondet_word();
  auto* id = reinterpret_cast<Smi*>(raw);
  image.set_task_class_id(id);
  word index = raw >> 1;
  bool in_table = (raw & 1) == 0 && index >= 0 && index < count;
  uint16 bits = nondet_ushort();
  if (in_table) classes[index] = bits;

  bool admitted = InitialMemoryManager::can_allocate_task(&image);
  word task_words = bits >> HeapObject::CLASS_ID_OFFSET;
  word stack_words = Stack::allocation_size(Stack::initial_length()) / WORD_SIZE;
  bool valid = in_table && (bits & Program::CLASS_TAG_MASK) == TASK_TAG &&
               task_words >= Instance::HEADER_SIZE / WORD_SIZE + Task::ID_INDEX + 1;
  CXXV_ASSERT(admitted == (valid && stack_words + task_words < TOIT_PAGE_SIZE / WORD_SIZE),
              "admit exactly a task with both required fields and room for both objects and the sentinel");
  if (!valid) return 0;

  uword page[TOIT_PAGE_SIZE / WORD_SIZE];
  uword start = reinterpret_cast<uword>(page);
  young.top_ = start;
  young.limit_ = start + sizeof(page);
  uword stack = young.allocate(stack_words * WORD_SIZE);
  CXXV_ASSERT(stack == start, "the initial stack fits on an empty page");
  uword task = young.try_allocate(task_words * WORD_SIZE);
  uword after_stack = start + stack_words * WORD_SIZE;
  CXXV_ASSERT(task == (admitted ? after_stack : 0), "the two native reservations agree with admission");
  CXXV_ASSERT(young.top_ == after_stack + (admitted ? task_words * WORD_SIZE : 0) &&
              young.top_ < young.limit_ && has_sentinel_at(young.top_),
              "the last successful reservation leaves an in-page sentinel");
}
