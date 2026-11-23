// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/two_space_heap.cc"
#undef protected
#undef private

using namespace toit;

extern ObjectHeap owner_heap;
extern Program image;
static Chunk* young_chunk;
static TwoSpaceHeap* heap;
static RootCallback* marker;
static FixPointersVisitor* fixer;
static uword survivors;
static word reclaimed;

enum Event {
  ROOTS, DRAIN, CALLBACK_FINALIZERS, FINALIZER_QUEUE, VM_FINALIZERS, PLAN,
  SWEEP, CLEAR_YOUNG, CLEAR_FREE_LIST, ZAP_STARTS, COMPACT_OLD, FIX_YOUNG,
  FIX_ROOTS, FIX_FINALIZERS, CLEAR_OLD, FREE_ENDS
};
static Event events[20];
static unsigned count;

static void record(Event event) {
  CXXV_ASSERT(count < ARRAY_SIZE(events), "collection runs a bounded sequence of phases");
  events[count++] = event;
}

namespace toit {
// The collection receives an already installed young-space chunk.
Chunk::Chunk(Space* owner, uword start, uword size)
    : owner_(owner), start_(start), end_(start + size), scavenge_pointer_(start) {}
Chunk::~Chunk() {}

uword Space::size() const {
  CXXV_ASSERT(this == heap->new_space(), "mark visitor uses this heap's young-space bounds");
  return young_chunk->size();
}

void ObjectHeap::iterate_roots(RootCallback* cb) {
  CXXV_ASSERT(this == &owner_heap && cb != nullptr, "enumerate this process's roots");
  if (marker == nullptr) {
    marker = cb;
    auto* m = static_cast<MarkingVisitor*>(cb);
    CXXV_ASSERT(m->program_ == &image && m->new_space_address_ == young_chunk->start() &&
                m->new_space_size_ == young_chunk->size(), "initialize marker from this collection's image and space");
    auto* stack = m->marking_stack_;
    CXXV_ASSERT(stack && stack->program_ == &image && stack->is_empty() && !stack->is_overflowed() &&
                stack->limit_ == stack->backing_ + 128, "begin with an empty bounded mark stack");
    record(ROOTS);
  } else {
    CXXV_ASSERT(cb == fixer && cb != marker, "update roots with the compaction visitor");
    record(FIX_ROOTS);
  }
}

void MarkingStack::process(RootCallback* cb, Space* old_space, Space* new_space) {
  CXXV_ASSERT(cb == marker && this == static_cast<MarkingVisitor*>(marker)->marking_stack_ &&
              old_space == heap->old_space() && new_space == heap->new_space(),
              "drain the same marker and both generations");
  record(DRAIN);
}

void ObjectHeap::process_registered_callback_finalizers(RootCallback* cb, LivenessOracle* oracle) {
  CXXV_ASSERT(this == &owner_heap && cb == marker && oracle == heap->old_space(), "callback liveness uses old-space marks");
  record(CALLBACK_FINALIZERS);
}
void ObjectHeap::process_finalizer_queue(RootCallback* cb, LivenessOracle* oracle) {
  CXXV_ASSERT(this == &owner_heap && cb == marker && oracle == heap->old_space(), "queued finalizers use the current marks");
  record(FINALIZER_QUEUE);
}
void ObjectHeap::process_registered_vm_finalizers(RootCallback* cb, LivenessOracle* oracle) {
  CXXV_ASSERT(this == &owner_heap && cb == marker && oracle == heap->old_space(), "VM finalizers use the current marks");
  record(VM_FINALIZERS);
}
word OldSpace::compute_compaction_destinations() {
  CXXV_ASSERT(this == heap->old_space(), "compute destinations for this old space");
  record(PLAN);
  return reclaimed;
}
uword OldSpace::sweep() {
  CXXV_ASSERT(this == heap->old_space() && !compacting_, "sweep in non-compacting mode");
  record(SWEEP);
  return survivors;
}
void OldSpace::clear_free_list() {
  CXXV_ASSERT(this == heap->old_space() && compacting_, "rebuild the free list in compacting mode");
  record(CLEAR_FREE_LIST);
}
void OldSpace::zap_object_starts() {
  CXXV_ASSERT(this == heap->old_space(), "reset old-space object starts");
  record(ZAP_STARTS);
}
// Object traversal supplies the survivor byte count. The actual movement
// and calculation of destinations are separate proof obligations.
CompactingVisitor::CompactingVisitor(Program* p, OldSpace* space, FixPointersVisitor* fix)
    : HeapObjectVisitor(p), used_(0), dest_(space->chunk_list_begin(), 0, 0), fix_pointers_visitor_(fix) {
  CXXV_ASSERT(p == &image && space == heap->old_space() && fix != nullptr, "bind compaction to this collection");
  fixer = fix;
}
void Space::iterate_objects(HeapObjectVisitor* v, LivenessOracle* filter) {
  CXXV_ASSERT(v && v->program_ == &image, "enumerate objects using this program");
  if (this == heap->old_space()) {
    CXXV_ASSERT(filter == nullptr, "old-space compaction processes its mark bitmap");
    static_cast<CompactingVisitor*>(v)->used_ = survivors;
    record(COMPACT_OLD);
  } else {
    CXXV_ASSERT(this == heap->new_space() && filter == heap->old_space() &&
                static_cast<HeapObjectPointerVisitor*>(v)->visitor_ == fixer, "fix only live young objects");
    record(FIX_YOUNG);
  }
}
void ObjectHeap::iterate_finalization_roots(RootCallback* cb) {
  CXXV_ASSERT(this == &owner_heap && cb == fixer, "fix finalizer slots before clearing marks");
  record(FIX_FINALIZERS);
}
void Space::clear_mark_bits() {
  CXXV_ASSERT(this == heap->new_space() || this == heap->old_space(), "clear only this heap's mark storage");
  record(this == heap->new_space() ? CLEAR_YOUNG : CLEAR_OLD);
}
void OldSpace::mark_chunk_ends_free() {
  CXXV_ASSERT(this == heap->old_space(), "restore the old-space tail regions");
  record(FREE_ENDS);
}
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  heap = &owner_heap.two_space_heap_;
  heap->program_ = &image;
  heap->process_heap_ = &owner_heap;
  heap->semi_space_.program_ = &image;
  uword start = nondet_ulong(), size = nondet_ulong();
  CXXV_ASSUME(size > 0 && start <= UINTPTR_MAX - size);
  Chunk chunk(&heap->semi_space_, start, size);
  young_chunk = &chunk;
  auto* anchor = &heap->semi_space_.chunk_list_.anchor_;
  anchor->next_ = anchor->prev_ = &chunk;
  chunk.next_ = chunk.prev_ = anchor;
  survivors = nondet_ulong();
  reclaimed = nondet_word();
  bool force = nondet_bool();
  bool compact = force || reclaimed > 0;
  heap->old_space_.compacting_ = nondet_bool();
  bool result = heap->perform_garbage_collection(force);
  CXXV_ASSERT(result == compact && heap->old_space_.compacting_ == compact, "return the selected collection mode");
  CXXV_ASSERT(heap->old_space_.used_ == survivors && heap->old_space_.used_after_last_gc_ == survivors,
              "publish the survivor byte count from the selected collector");
  const Event prefix[] = {
    ROOTS, DRAIN, CALLBACK_FINALIZERS, FINALIZER_QUEUE, DRAIN, VM_FINALIZERS, DRAIN, PLAN
  };
  const Event sweep[] = {SWEEP, CLEAR_YOUNG};
  const Event move[] = {
    CLEAR_FREE_LIST, ZAP_STARTS, COMPACT_OLD, FIX_YOUNG, FIX_ROOTS, FIX_FINALIZERS, CLEAR_YOUNG, CLEAR_OLD, FREE_ENDS
  };
  unsigned tail_length = compact ? ARRAY_SIZE(move) : ARRAY_SIZE(sweep);
  CXXV_ASSERT(count == ARRAY_SIZE(prefix) + tail_length, "run exactly the selected phases");
  for (unsigned i = 0; i < ARRAY_SIZE(prefix); ++i) {
    CXXV_ASSERT(events[i] == prefix[i], "complete each marking wave before consuming its liveness result");
  }
  for (unsigned i = 0; i < tail_length; ++i) {
    CXXV_ASSERT(events[ARRAY_SIZE(prefix) + i] == (compact ? move[i] : sweep[i]),
                "finish pointer updates before releasing mark data");
  }
}
