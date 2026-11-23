// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "heap.cc"
#undef protected
#undef private

using namespace toit;

extern Process subject;
extern Mutex heap_mutex;
extern Task previous_task, next_task;
static bool locked, collected, released, requested;
static GcType outcome;
static uword initial_epoch, old_bytes, young_bytes;
static ObjectHeap* heap;

void Locker::enter() {
  CXXV_ASSERT(!locked && !collected && mutex() == &heap_mutex, "take this process's heap lock once");
  locked = true;
}

void Locker::leave() {
  CXXV_ASSERT(locked && collected && mutex() == &heap_mutex, "release the heap lock after collection");
  CXXV_ASSERT(*heap->v2_epoch_address() == initial_epoch + uword{1} && heap->retrying_primitive(),
              "publish epoch and retry state before releasing the lock");
  locked = false;
  released = true;
}

GcType TwoSpaceHeap::collect_new_space(bool try_hard) {
  CXXV_ASSERT(locked && !collected && this == &heap->two_space_heap_ && try_hard == requested,
              "collect the caller's two-space heap once in the requested mode");
  CXXV_ASSERT(*heap->v2_epoch_address() == initial_epoch, "advance the epoch only after collection");
  collected = true;
  return outcome;
}

uword Space::size() const {
  CXXV_ASSERT(locked && collected && outcome != NEW_SPACE_GC, "measure post-collection space under lock");
  if (this == heap->two_space_heap_.old_space()) return old_bytes;
  CXXV_ASSERT(this == heap->two_space_heap_.new_space(), "measure the current young space");
  return young_bytes;
}

static int valid_counter() {
  int n = nondet_int();
  CXXV_ASSUME(n >= 0 && n <= Smi::MAX_SMI_VALUE);
  return n;
}

static int increment(int n) {
  return n == INT_MAX || n == Smi::MAX_SMI_VALUE ? 0 : n + 1;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  heap = subject.object_heap();
  heap->mutex_ = &heap_mutex;
  initial_epoch = nondet_ulong();
  heap->v2_epoch_ = initial_epoch;
  int kind = nondet_int();
  CXXV_ASSUME(kind >= NEW_SPACE_GC && kind <= COMPACTING_GC);
  outcome = static_cast<GcType>(kind);
  requested = nondet_bool();
  int all = valid_counter(), full = valid_counter(), compact = valid_counter();
  heap->gc_count_ = all;
  heap->full_gc_count_ = full;
  heap->full_compacting_gc_count_ = compact;
  old_bytes = nondet_ulong();
  young_bytes = nondet_ulong();
  CXXV_ASSUME(young_bytes <= UINTPTR_MAX - old_bytes);
  uword external = nondet_ulong();
  heap->external_memory_.store(external);
  word cap = nondet_word(), limit = nondet_word(), pending = nondet_word();
  CXXV_ASSUME(cap >= 0);
  heap->max_heap_size_ = cap;
  heap->limit_ = limit;
  heap->pending_limit_ = pending;
  heap->retrying_primitive_ = nondet_bool();

  auto* epoch = heap->v2_epoch_address();
  GcType result = subject.gc(requested);
  CXXV_ASSERT(released && !locked && result == outcome, "return the collection kind after unlocking");
  CXXV_ASSERT(*epoch == initial_epoch + uword{1} && *epoch != initial_epoch, "one observable epoch tick including wrap");
  CXXV_ASSERT(subject.gc_count(NEW_SPACE_GC) == increment(all) &&
              subject.gc_count(FULL_GC) == (kind == NEW_SPACE_GC ? full : increment(full)) &&
              subject.gc_count(COMPACTING_GC) == (kind == COMPACTING_GC ? increment(compact) : compact),
              "account for exactly the reported collection kind");
  if (kind == NEW_SPACE_GC) {
    CXXV_ASSERT(heap->limit_ == limit && heap->pending_limit_ == pending, "young collection preserves both limits");
  } else {
    uword internal = old_bytes + young_bytes;
    uword total = external > UINTPTR_MAX - internal ? UINTPTR_MAX : internal + external;
    word next = total > INTPTR_MAX / 2 ? INTPTR_MAX : static_cast<word>(total * 2);
    if (next < TOIT_PAGE_SIZE) next = TOIT_PAGE_SIZE;
    if (cap > 0) next = next > cap / 2 ? cap : next * 2;
    CXXV_ASSERT(heap->limit_ == cap && heap->pending_limit_ == next, "full collection publishes hard and pending limits");
  }
  heap->task_ = &previous_task;
  Task* destination = nondet_bool() ? &previous_task : &next_task;
  auto before_switch = *epoch;
  heap->set_task(destination);
  CXXV_ASSERT(subject.task() == destination && *epoch == before_switch + uword{1},
              "task publication advances the same epoch even on a same-task switch");
}
