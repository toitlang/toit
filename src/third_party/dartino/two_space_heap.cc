// Copyright (c) 2014, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "../../flags.h"
#include "../../heap.h"
#include "../../top.h"
#include "../../objects.h"
#include "two_space_heap.h"
#include "mark_sweep.h"

namespace toit {

TwoSpaceHeap::TwoSpaceHeap(Program* program, ObjectHeap* process_heap, Chunk* chunk_1, Chunk* chunk_2)
    : program_(program),
      process_heap_(process_heap),
      old_space_(program, this),
      semi_space_a_(program, chunk_1),
      semi_space_b_(program, chunk_2),
      semi_space_(&semi_space_a_),
      unused_semi_space_(&semi_space_b_) {
  semi_space_size_ = TOIT_PAGE_SIZE;
  max_size_ = 256 * TOIT_PAGE_SIZE;
}

bool TwoSpaceHeap::initialize() {
  Chunk* chunk = ObjectMemory::allocate_chunk(semi_space_, semi_space_size_);
  if (chunk == NULL) return false;
  Chunk* unused_chunk =
      ObjectMemory::allocate_chunk(unused_semi_space_, semi_space_size_);
  if (unused_chunk == NULL) {
    ObjectMemory::free_chunk(chunk);
    return false;
  }
  semi_space_->append(chunk);
  semi_space_->update_base_and_limit(chunk, chunk->start());
  unused_semi_space_->append(unused_chunk);
  water_mark_ = chunk->start();
  return true;
}

TwoSpaceHeap::~TwoSpaceHeap() {
  // TODO(erik): Call all finalizers.
}

HeapObject* TwoSpaceHeap::allocate(uword size) {
  uword result = semi_space_->allocate(size);
  if (result == 0) {
    return new_space_allocation_failure(size);
  }
  return HeapObject::from_address(result);
}

void TwoSpaceHeap::swap_semi_spaces() {
  SemiSpace* temp = semi_space_;
  semi_space_ = unused_semi_space_;
  unused_semi_space_ = temp;
  water_mark_ = semi_space_->top();
}

SemiSpace* TwoSpaceHeap::take_space() {
  SemiSpace* result = semi_space_;
  semi_space_ = NULL;
  return result;
}

template <class SomeSpace>
HeapObject* ScavengeVisitor::clone_into_space(Program* program, HeapObject* original, SomeSpace* to) {
  ASSERT(!to->includes(original->_raw()));
  ASSERT(!original->has_forwarding_address());
  // Copy the object to the 'to' space and insert a forwarding pointer.
  int object_size = original->size(program);
  uword new_address = to->allocate(object_size);
  if (new_address == 0) return null;
  HeapObject* target = HeapObject::from_address(new_address);
  // Copy the content of source to target.
  memcpy(reinterpret_cast<void*>(new_address), reinterpret_cast<void*>(original->_raw()), object_size);
  original->set_forwarding_address(target);
  return target;
}

void ScavengeVisitor::do_roots(Object** start, int count) {
  Object** end = start + count;
  for (Object** p = start; p < end; p++) {
    if (!in_from_space(*p)) continue;
    HeapObject* old_object = reinterpret_cast<HeapObject*>(*p);
    if (old_object->has_forwarding_address()) {
      HeapObject* destination = old_object->forwarding_address();
      *p = destination;
      if (in_to_space(destination)) *record_ = GcMetadata::NEW_SPACE_POINTERS;
    } else {
      if (old_object->_raw() < water_mark_) {
        HeapObject* moved_object = clone_into_space(program_, old_object, old_);
        // The old space may fill up.  This is a bad moment for a GC, so we
        // promote to the to-space instead.
        if (moved_object == NULL) {
          trigger_old_space_gc_ = true;
          moved_object = clone_into_space(program_, old_object, to_);
          *record_ = GcMetadata::NEW_SPACE_POINTERS;
        }
        *p = moved_object;
      } else {
        *p = clone_into_space(program_, old_object, to_);
        *record_ = GcMetadata::NEW_SPACE_POINTERS;
      }
      ASSERT(*p != NULL);  // In an emergency we can move to to-space.
    }
  }
}

void SemiSpace::start_scavenge() {
  flush();

  for (auto chunk : chunk_list_) chunk->set_scavenge_pointer(chunk->start());
}

#ifndef LEGACY_GC

void TwoSpaceHeap::collect_new_space() {
  SemiSpace* from = space();

  uint64 start = OS::get_monotonic_time();

  if (has_empty_new_space()) {
    collect_old_space_if_needed(false);
    if (Flags::tracegc) {
      uint64 end = OS::get_monotonic_time();
      printf("Old-space-only GC: %dus\n", static_cast<int>(end - start));
    }
    return;
  }

  old_space()->flush();
  from->flush();

  old_space()->rebuild_remembered_set();

#ifdef DEBUG
  if (Flags::validate_heap) old_space()->verify();
#endif

  SemiSpace* to = unused_space();

  uword old_used = old_space()->used();

  to->set_used(0);
  // Allocate from start of to-space..
  to->update_base_and_limit(to->chunk(), to->chunk()->start());

  ScavengeVisitor visitor(program_, this);
  to->start_scavenge();
  old_space()->start_scavenge();

  process_heap_->iterate_roots(&visitor);

  old_space()->visit_remembered_set(&visitor);

  bool work_found = true;
  while (work_found) {
    work_found = to->complete_scavenge(&visitor);
    work_found |= old_space()->complete_scavenge(&visitor);
  }

  process_heap_->process_registered_finalizers(&visitor, from);

  work_found = true;
  while (work_found) {
    work_found = to->complete_scavenge(&visitor);
    work_found |= old_space()->complete_scavenge(&visitor);
  }

  process_heap_->process_registered_vm_finalizers(&visitor, from);

  work_found = true;
  while (work_found) {
    work_found = to->complete_scavenge(&visitor);
    work_found |= old_space()->complete_scavenge(&visitor);
  }

  old_space()->end_scavenge();

  // Second space argument is used to size the new-space.
  swap_semi_spaces();

#ifdef DEBUG
  if (Flags::validate_heap) old_space()->verify();
#endif

  if (Flags::tracegc) {
    uint64 end = OS::get_monotonic_time();
    int f = from->used();
    int t = to->used();
    printf("Scavenge: %d%c->%d%c, %dus\n",
        (f >> 10) ? (f >> 10) : f,
        (f >> 10) ? 'k' : 'b',
        (t >> 10) ? (t >> 10) : t,
        (t >> 10) ? 'k' : 'b',
        static_cast<int>(end - start));
  }

  ASSERT(from->used() >= to->used());
  // Find out how much garbage was found.
  word progress = (from->used() - to->used()) - (old_space()->used() - old_used);
  // There's a little overhead when allocating in old space which was not there
  // in new space, so we might overstate the number of promoted bytes a little,
  // which could result in an understatement of the garbage found, even to make
  // it negative.
  if (progress > 0) {
    old_space()->report_new_space_progress(progress);
  }
  collect_old_space_if_needed(visitor.trigger_old_space_gc());
}

void TwoSpaceHeap::collect_old_space_if_needed(bool force) {
  if (force || old_space()->needs_garbage_collection()) {
    old_space()->flush();
    collect_old_space();
#ifdef DEBUG
    if (Flags::validate_heap) old_space()->verify();
#endif
  }
}

void TwoSpaceHeap::validate() {
#ifdef DEBUG
  // TODO (erik).
#endif
}

void TwoSpaceHeap::collect_old_space() {
  if (Flags::validate_heap) {
    validate();
  }

  uint64 start = OS::get_monotonic_time();
  uword old_size = old_space()->used();

  bool compacted = perform_garbage_collection();

  if (Flags::tracegc) {
    uint64 end = OS::get_monotonic_time();
    int f = old_size;
    int t = old_space()->used();
    printf("Mark-sweep%s: %d%c->%d%c, %dus\n",
        compacted ? "-compact" : "",
        (f >> 10) ? (f >> 10) : f,
        (f >> 10) ? 'k' : 'b',
        (t >> 10) ? (t >> 10) : t,
        (t >> 10) ? 'k' : 'b',
        static_cast<int>(end - start));
  }

  old_space()->set_allocation_budget(Utils::min(
      static_cast<uword>(TOIT_PAGE_SIZE),
      static_cast<uword>(old_space()->used() * 1.5)));

  if (Flags::validate_heap) {
    validate();
  }
  // TODO(Erik): The heuristics need tidying.
  old_space()->adjust_allocation_budget(0);
}

bool TwoSpaceHeap::perform_garbage_collection() {
  // Mark all reachable objects.  We mark all live objects in new-space too, to
  // detect liveness paths that go through new-space, but we just clear the
  // mark bits afterwards.  Dead objects in new-space are only cleared in a
  // new-space GC (scavenge).
  SemiSpace* new_space = space();
  MarkingStack stack(program_);
  MarkingVisitor marking_visitor(new_space, &stack);

  process_heap_->iterate_roots(&marking_visitor);

  stack.process(&marking_visitor, old_space(), new_space);

  process_heap_->process_registered_finalizers(&marking_visitor, old_space());

  stack.process(&marking_visitor, old_space(), new_space);

  process_heap_->process_registered_vm_finalizers(&marking_visitor, old_space());

  stack.process(&marking_visitor, old_space(), new_space);

  bool compact = !old_space()->compacting();

  if (!compact) {
    // If the last GC was compacting we don't have fragmentation, so it
    // is fair to evaluate if we are making progress or just doing
    // pointless GCs.
    old_space()->evaluate_pointlessness();
    // Do a non-compacting GC this time for speed.
    sweep_heap();
  } else {
    // Last GC was sweeping, so we do a compaction this time to avoid
    // fragmentation.
    compact_heap();
  }

#ifdef DEBUG
  if (Flags::validate_heap) old_space()->verify();
#endif

  return compact;
}

void TwoSpaceHeap::sweep_heap() {
  SemiSpace* new_space = space();

  old_space()->set_compacting(false);

  old_space()->process_weak_pointers();

  // Sweep over the old-space and rebuild the freelist.
  SweepingVisitor sweeping_visitor(program_, old_space());
  old_space()->iterate_objects(&sweeping_visitor);

  // These are only needed during the mark phase, we can clear them without
  // looking at them.
  new_space->clear_mark_bits();

  uword used_after = sweeping_visitor.used();
  old_space()->set_used(used_after);
  old_space()->set_used_after_last_gc(used_after);
}

// Class for visiting pointers inside heap objects.
class HeapObjectPointerVisitor : public HeapObjectVisitor {
 public:
  HeapObjectPointerVisitor(Program* program, RootCallback* visitor)
      : HeapObjectVisitor(program)
      , visitor_(visitor) {}
  virtual ~HeapObjectPointerVisitor() {}

  virtual uword visit(HeapObject* object) {
    uword size = object->size(program_);
    object->roots_do(program_, visitor_);
    return size;
  }

 private:
  RootCallback* visitor_;
};

class EverythingIsAlive : public LivenessOracle {
 public:
  bool is_alive(HeapObject* object) { return true; }
};

void TwoSpaceHeap::compact_heap() {
  SemiSpace* new_space = space();

  old_space()->set_compacting(true);

  old_space()->compute_compaction_destinations();

  old_space()->clear_free_list();

  // Weak processing when the destination addresses have been calculated, but
  // before they are moved (which ruins the liveness data).
  old_space()->process_weak_pointers();

  old_space()->zap_object_starts();

  FixPointersVisitor fix;
  CompactingVisitor compacting_visitor(program_, old_space(), &fix);
  old_space()->iterate_objects(&compacting_visitor);
  uword used_after = compacting_visitor.used();
  old_space()->set_used(used_after);
  old_space()->set_used_after_last_gc(used_after);
  fix.set_source_address(0);

  HeapObjectPointerVisitor new_space_visitor(program_, &fix);
  new_space->iterate_objects(&new_space_visitor);

  process_heap_->iterate_roots(&fix);
  // At this point dead objects have been cleared out of the finalizer lists.
  EverythingIsAlive yes;
  process_heap_->process_registered_finalizers(&fix, &yes);
  process_heap_->process_registered_vm_finalizers(&fix, &yes);

  new_space->clear_mark_bits();
  old_space()->clear_mark_bits();
  old_space()->mark_chunk_ends_free();
}

#endif

#ifdef DEBUG
void TwoSpaceHeap::find(uword word) {
  semi_space_->find(word, "data semi_space");
  unused_semi_space_->find(word, "unused semi_space");
  old_space_.find(word, "oldspace");
#ifdef DARTINO_TARGET_OS_LINUX
  FILE* fp = fopen("/proc/self/maps", "r");
  if (fp == NULL) return;
  size_t length;
  char* line = NULL;
  while (getline(&line, &length, fp) > 0) {
    char* start;
    char* end;
    char r, w, x, p;  // Permissions.
    char filename[1000];
    memset(filename, 0, 1000);
    sscanf(line, "%p-%p %c%c%c%c %*x %*5c %*d %999c", &start, &end, &r, &w, &x,
           &p, &(filename[0]));
    // Don't search in mapped files.
    if (filename[0] != 0 && filename[0] != '[') continue;
    if (filename[0] == 0) {
      snprintf(filename, sizeof(filename), "anonymous: %p-%p %c%c%c%c", start,
               end, r, w, x, p);
    } else {
      if (filename[strlen(filename) - 1] == '\n') {
        filename[strlen(filename) - 1] = 0;
      }
    }
    // If we can't read it, skip.
    if (r != 'r') continue;
    for (char* current = start; current < end; current += 4) {
      uword w = *reinterpret_cast<uword*>(current);
      if (w == word) {
        fprintf(stderr, "Found %p in %s at %p\n", reinterpret_cast<void*>(w),
                filename, current);
      }
    }
  }
  fclose(fp);
#endif  // __linux
}
#endif  // DEBUG

}  // namespace toit
