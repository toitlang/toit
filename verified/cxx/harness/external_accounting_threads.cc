// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include <pthread.h>
#define private public
#define protected public
#include "heap.cc"
#undef protected
#undef private

using namespace toit;

static ObjectHeap* heap;
static word added;
static word released;

static void* register_bytes(void*) {
  heap->register_external_allocation(added);
  return nullptr;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS && sizeof(uword) == sizeof(unsigned long), "word domain");
  heap = new ObjectHeap(nullptr, nullptr, nullptr, nullptr, nullptr);
  CXXV_ASSUME(heap != nullptr);
  uword before = nondet_ulong();
  added = nondet_word();
  released = nondet_word();
  CXXV_ASSUME(added >= 0 && released >= 0);
  CXXV_ASSUME(static_cast<uword>(added) <= UINTPTR_MAX - before);
  CXXV_ASSUME(static_cast<uword>(released) <= before);
  heap->external_memory_.store(before);
  pthread_t worker;
  int started = pthread_create(&worker, nullptr, register_bytes, nullptr);
  CXXV_ASSUME(started == 0);
  heap->unregister_external_allocation(released);
  int joined = pthread_join(worker, nullptr);
  CXXV_ASSUME(joined == 0);
  CXXV_ASSERT(heap->external_memory() == before + static_cast<uword>(added) - static_cast<uword>(released),
              "concurrent registration and release preserve both changes");
  CXXV_ASSERT(heap->total_external_memory_.load() == static_cast<uint64>(added),
              "only registration contributes to the lifetime total");
}
