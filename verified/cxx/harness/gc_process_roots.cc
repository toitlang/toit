// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "heap.cc"
#undef protected
#undef private

using namespace toit;

extern ObjectNotifier early, late;
extern Program image;

class RecordingRoots : public RootCallback {
 public:
  Object** expected[6];
  unsigned calls = 0;
  unsigned ranges = 0;
  int global_count;

  void expect(Object** slot) { expected[ranges++] = slot; }

  void do_roots(Object** roots, word count) override {
    CXXV_ASSERT(calls < ranges && roots == expected[calls], "visit the actual storage in registration order");
    bool globals = calls == 1;
    CXXV_ASSERT(count == (globals ? global_count : 1), "only globals form a variable-length range");
    ++calls;
  }
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  Object* global_slot = nullptr;
  int n = nondet_int();
  CXXV_ASSUME(n >= 0 && static_cast<uword>(n) <= INTPTR_MAX / WORD_SIZE);
  // The recording visitor only observes the address and count of a range.
  Object** globals = n == 0 && nondet_bool() ? nullptr : &global_slot;
  auto* heap = new ObjectHeap(&image, nullptr, nullptr, globals, nullptr);
  image.global_variables.length_ = n;

  HeapRoot first(nullptr), second(nullptr);
  bool keep_first = nondet_bool(), keep_second = nondet_bool();
  bool keep_early = nondet_bool(), keep_late = nondet_bool();
  auto* external = &heap->external_roots_.anchor_;
  first.next_ = external;
  second.next_ = keep_first ? &first : external;
  external->next_ = keep_second ? &second : second.next_;
  auto* notifiers = &heap->object_notifiers_.anchor_;
  early.next_ = notifiers;
  late.next_ = keep_early ? &early : notifiers;
  notifiers->next_ = keep_late ? &late : late.next_;

  RecordingRoots visitor;
  visitor.global_count = n;
  visitor.expect(reinterpret_cast<Object**>(&heap->task_));
  visitor.expect(globals);
  if (keep_second) visitor.expect(&second.obj_);
  if (keep_first) visitor.expect(&first.obj_);
  if (keep_late) visitor.expect(&late.object_);
  if (keep_early) visitor.expect(&early.object_);
  heap->iterate_roots(&visitor);
  CXXV_ASSERT(visitor.calls == visitor.ranges, "enumerate every registered root including the empty global range");
}
