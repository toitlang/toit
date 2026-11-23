// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "heap.cc"
#undef private

using namespace toit;

extern Program image;
extern Process caller;

HeapObject* TwoSpaceHeap::allocate(uword) {
  CXXV_ASSERT(false, "an exhausted task id must be rejected before allocation");
  return nullptr;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  auto* heap = new ObjectHeap(&image, &caller, nullptr, nullptr, nullptr);
  CXXV_ASSUME(heap != nullptr);
  uint32 next = nondet_uint();
  uint32 limit = sizeof(word) == 4 ? (UINT32_C(1) << 30) - 1 : INT32_MAX;
  CXXV_ASSUME(next > limit);
  caller.next_task_id_ = next;
  auto* task = heap->allocate_task();
  CXXV_ASSERT(task == nullptr && heap->last_allocation_result_ == ObjectHeap::ALLOCATION_HIT_LIMIT,
              "return allocation failure and report the exhausted limit");
  CXXV_ASSERT(caller.next_task_id_ == next, "retain the exhausted counter for subsequent attempts");
}
