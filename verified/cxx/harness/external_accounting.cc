// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "heap.cc"
#undef protected
#undef private

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  static_assert(sizeof(uword) == sizeof(unsigned long), "input spans every unsigned word");
  ObjectHeap* heap = new ObjectHeap(nullptr, nullptr, nullptr, nullptr, nullptr);
  CXXV_ASSUME(heap != nullptr);
  CXXV_ASSERT(heap->external_memory() == 0, "an empty heap starts with zero external bytes");
  CXXV_ASSERT(heap->total_external_memory_.load() == 0, "lifetime external bytes start at zero");
  uword before = nondet_ulong();
  heap->external_memory_.store(before);
  CXXV_ASSERT(heap->external_memory() == before, "external reading preserves every bit");

  word size = nondet_word();
  CXXV_ASSUME(size >= 0);
  uint64 lifetime = static_cast<uint64>(nondet_int64());
  heap->total_external_memory_.store(lifetime);
  if (nondet_bool()) {
    CXXV_ASSUME(static_cast<uword>(size) <= UINTPTR_MAX - before);
    heap->register_external_allocation(size);
    CXXV_ASSERT(heap->external_memory() == before + static_cast<uword>(size), "register adds the exact external size");
    CXXV_ASSERT(heap->total_external_memory_.load() == lifetime + static_cast<uint64>(size), "registration updates lifetime bytes modulo 2^64");
  } else {
    CXXV_ASSUME(static_cast<uword>(size) <= before);
    heap->unregister_external_allocation(size);
    CXXV_ASSERT(heap->external_memory() == before - static_cast<uword>(size), "unregister removes the exact external size");
    CXXV_ASSERT(heap->total_external_memory_.load() == lifetime, "release preserves lifetime bytes");
  }
}
