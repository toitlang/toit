// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/two_space_heap.cc"
#undef protected
#undef private

using namespace toit;
extern TwoSpaceHeap heap;
extern ObjectHeap process_heap;
extern Program image;
static ScavengeVisitor* visitor;
static Chunk* destination;
static uword survivors;
static bool young_work, old_work, scanned_young, found_young;

enum Phase { INITIAL, FLUSHED, TRACKING, ROOTS, REMEMBERED, STRONG_DRAINED, CALLBACKS, QUEUE,
             REVIVED_DRAINED, VM_FINALIZERS, FINAL_DRAINED, FINISHED };
static Phase phase = INITIAL;
// A promoted object can reveal more young work once per modeled drain.
static bool added_young_from_old;

Chunk::Chunk(Space* space, uword start, uword size)
    : owner_(space), start_(start), end_(start + size), scavenge_pointer_(start) {}
Chunk::~Chunk() {}
Space::Space(Program* p, Resizing, PageType type) : program_(p), page_type_(type) {}
Space::~Space() {}
SemiSpace::SemiSpace(Program* p, Chunk* chunk) : Space(p, CANNOT_RESIZE, NEW_SPACE_PAGE) {
  if (chunk) chunk_list_.append(chunk);
}

void SemiSpace::flush() {
  CXXV_ASSERT(phase == INITIAL && this == visitor->to_space(), "flush the destination before tracking");
  phase = FLUSHED;
}
void OldSpace::start_scavenge() {
  CXXV_ASSERT(phase == FLUSHED && this == heap.old_space() &&
              destination->scavenge_pointer() == destination->start(), "reset the copy cursor before tracking promotions");
  phase = TRACKING;
}
static void add_work() {
  young_work |= nondet_bool();
  old_work |= nondet_bool();
}
void ObjectHeap::iterate_roots(RootCallback* v) {
  CXXV_ASSERT(phase == TRACKING && this == &process_heap && v == visitor, "visit process roots while tracking");
  add_work();
  phase = ROOTS;
}
void OldSpace::visit_remembered_set(ScavengeVisitor* v) {
  CXXV_ASSERT(phase == ROOTS && this == heap.old_space() && v == visitor, "include remembered edges before finalization");
  add_work();
  phase = REMEMBERED;
}
bool SemiSpace::complete_scavenge(ScavengeVisitor* v) {
  CXXV_ASSERT((phase == REMEMBERED || phase == QUEUE || phase == VM_FINALIZERS) &&
              this == visitor->to_space() && v == visitor && !scanned_young, "scan young work in the current drain");
  scanned_young = true;
  found_young = young_work;
  if (young_work) old_work |= nondet_bool();  // A young edge can cause promotion.
  young_work = false;
  return found_young;
}
bool OldSpace::complete_scavenge(ScavengeVisitor* v) {
  CXXV_ASSERT(scanned_young && this == heap.old_space() && v == visitor, "scan promoted work in the same drain");
  scanned_young = false;
  bool found_old = old_work;
  old_work = false;
  if (found_old && !added_young_from_old && nondet_bool()) {
    young_work = true;
    added_young_from_old = true;
  }
  if (!found_old && !found_young) {
    added_young_from_old = false;
    phase = phase == REMEMBERED ? STRONG_DRAINED : phase == QUEUE ? REVIVED_DRAINED : FINAL_DRAINED;
  }
  return found_old;
}
static void visit_finalizers(ObjectHeap* h, RootCallback* v, LivenessOracle* from, Phase before, Phase after) {
  CXXV_ASSERT(h == &process_heap && v == visitor && from == heap.new_space() && phase == before,
              "process the correct finalizer list with the source liveness oracle");
  add_work();
  phase = after;
}
void ObjectHeap::process_registered_callback_finalizers(RootCallback* v, LivenessOracle* from) {
  visit_finalizers(this, v, from, STRONG_DRAINED, CALLBACKS);
}
void ObjectHeap::process_finalizer_queue(RootCallback* v, LivenessOracle* from) {
  visit_finalizers(this, v, from, CALLBACKS, QUEUE);
}
void ObjectHeap::process_registered_vm_finalizers(RootCallback* v, LivenessOracle* from) {
  visit_finalizers(this, v, from, REVIVED_DRAINED, VM_FINALIZERS);
}
void OldSpace::end_scavenge() {
  CXXV_ASSERT(this == heap.old_space() && phase == FINAL_DRAINED && !young_work && !old_work,
              "end tracking after the last empty scan of both spaces");
  phase = FINISHED;
}
uword SemiSpace::used() const {
  CXXV_ASSERT(this == visitor->to_space() && phase == FINISHED, "measure survivors after processing all finalizers");
  return survivors;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  Chunk source(nullptr, TOIT_PAGE_SIZE, TOIT_PAGE_SIZE), spare(nullptr, 2 * TOIT_PAGE_SIZE, TOIT_PAGE_SIZE);
  new (heap.new_space()) SemiSpace(&image, &source);
  heap.process_heap_ = &process_heap;
  ScavengeVisitor collector(&image, &heap, &spare);
  visitor = &collector;
  destination = &spare;
  spare.set_scavenge_pointer(spare.start() + WORD_SIZE);
  survivors = nondet_ulong();
  CXXV_ASSUME(survivors < TOIT_PAGE_SIZE && survivors % WORD_SIZE == 0);
  uint64 before = static_cast<uint64>(nondet_int64());
  CXXV_ASSUME(before >= survivors);
  heap.total_bytes_allocated_ = before;
  heap.do_scavenge(visitor);
  CXXV_ASSERT(phase == FINISHED && heap.total_bytes_allocated_.load() == before - survivors,
              "complete all three drains and deduct exactly the final survivor size");
}
