// Copyright (c) 2014, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "../../top.h"

#ifndef LEGACY_GC

#include "../../flags.h"
#include "../../heap.h"
#include "../../objects.h"
#include "two_space_heap.h"
#include "mark_sweep.h"

namespace toit {

TwoSpaceHeap::TwoSpaceHeap(Program* program, ObjectHeap* process_heap, Chunk* chunk)
    : program_(program),
      process_heap_(process_heap),
      old_space_(program, this),
      semi_space_(program, chunk) {
  semi_space_size_ = TOIT_PAGE_SIZE;
  if (chunk) water_mark_ = chunk->start();
}

uword TwoSpaceHeap::max_expansion() {
  if (!process_heap_->has_max_heap_size()) return UNLIMITED_EXPANSION;
  uword limit = process_heap_->limit();
  if (limit <= TOIT_PAGE_SIZE) return 0;
  limit -= TOIT_PAGE_SIZE;  // New space is one page.
  if (limit < old_space()->used()) return 0;
  return old_space()->used() - limit;
}

TwoSpaceHeap::~TwoSpaceHeap() {
  // TODO(erik): Call all finalizers.
}

HeapObject* TwoSpaceHeap::allocate(uword size) {
  uword result = semi_space_.allocate(size);
  if (result == 0) {
    return new_space_allocation_failure(size);
  }
  return HeapObject::from_address(result);
}

void TwoSpaceHeap::swap_semi_spaces(SemiSpace& from, SemiSpace& to) {
  water_mark_ = to.top();
  if (old_space()->is_empty() && to.used() < TOIT_PAGE_SIZE / 2) {
    // Don't start promoting to old space until the post GC heap size
    // hits at least half a page.
    water_mark_ = to.single_chunk_start();
  }
  if (process_heap_->has_max_heap_size()) {
    uword limit = process_heap_->limit();
    if (limit <= TOIT_PAGE_SIZE) {
      // If we can't expand old space it's faster to not even try.
      water_mark_ = to.single_chunk_start();
    }
  }
  swap(from, to);
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
          moved_object = clone_into_space(program_, old_object, &to_);
          *record_ = GcMetadata::NEW_SPACE_POINTERS;
        }
        *p = moved_object;
      } else {
        *p = clone_into_space(program_, old_object, &to_);
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

  total_bytes_allocated_ += from->used();

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

#ifdef DEBUG
  if (Flags::validate_heap) validate();
#endif

  uword old_used = old_space()->used();
  word from_used;
  word to_used;
  bool trigger_old_space_gc;

  {
    Locker locker(ObjectMemory::spare_chunk_mutex());
    Chunk* spare_chunk = ObjectMemory::spare_chunk(locker);

    ScavengeVisitor visitor(program_, this, spare_chunk);
    SemiSpace* to = visitor.to_space();
    to->start_scavenge();
    old_space()->start_scavenge();

    process_heap_->iterate_roots(&visitor);

    old_space()->visit_remembered_set(&visitor);

    visitor.complete_scavenge();

    process_heap_->process_registered_finalizers(&visitor, from);

    visitor.complete_scavenge();

    process_heap_->process_registered_vm_finalizers(&visitor, from);

    visitor.complete_scavenge();

    old_space()->end_scavenge();

    total_bytes_allocated_ -= to->used();

    from_used = from->used();
    to_used = to->used();
    trigger_old_space_gc = visitor.trigger_old_space_gc();

    Chunk* spare_chunk_after = from->remove_chunk();

    ObjectMemory::set_spare_chunk(locker, spare_chunk_after);

    swap_semi_spaces(*from, *to);
  }

  if (Flags::tracegc) {
    uint64 end = OS::get_monotonic_time();
    int f = from_used;
    int t = to_used;
    int old = old_space()->used();
    printf("%p Scavenge: %d%c->%d%c (old-gen %d%c) %dus\n",
        process_heap_->owner(),
        (f >> 10) ? (f >> 10) : f,
        (f >> 10) ? 'k' : 'b',
        (t >> 10) ? (t >> 10) : t,
        (t >> 10) ? 'k' : 'b',
        (old >> 10) ? (old >> 10) : old,
        (old >> 10) ? 'k' : 'b',
        static_cast<int>(end - start));
  }

  ASSERT(from_used >= to_used);
  // Find out how much garbage was found.
  word progress = (from_used - to_used) - (old_space()->used() - old_used);
  // There's a little overhead when allocating in old space which was not there
  // in new space, so we might overstate the number of promoted bytes a little,
  // which could result in an understatement of the garbage found, even to make
  // it negative.
  if (progress > 0) {
    old_space()->report_new_space_progress(progress);
  }

  collect_old_space_if_needed(trigger_old_space_gc);
}

uword TwoSpaceHeap::total_bytes_allocated() {
  uword result = total_bytes_allocated_;
  result += space()->used();
  return result;
}

void TwoSpaceHeap::collect_old_space_if_needed(bool force) {
#ifdef DEBUG
  if (Flags::validate_heap) {
    validate();
    old_space()->validate_before_mark_sweep(OLD_SPACE_PAGE, false);
    space()->validate_before_mark_sweep(NEW_SPACE_PAGE, true);
  }
#endif
  if (force || old_space()->needs_garbage_collection()) {
    ASSERT(old_space()->is_flushed());
    ASSERT(space()->is_flushed());
    collect_old_space();
  }
}

#ifdef DEBUG
void TwoSpaceHeap::validate() {
  space()->validate();
  old_space()->validate();
}
#endif

void TwoSpaceHeap::collect_old_space() {

  uint64 start = OS::get_monotonic_time();
  uword old_size = old_space()->used();

  bool compacted = perform_garbage_collection();

  if (Flags::tracegc) {
    uint64 end = OS::get_monotonic_time();
    int f = old_size;
    int t = old_space()->used();
    printf("%p Mark-sweep%s: %d%c->%d%c, %dus\n",
        process_heap_->owner(),
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

#ifdef DEBUG
  if (Flags::validate_heap) {
    validate();
  }
#endif
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
  if (Flags::validate_heap) validate();
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
  semi_space_.find(word, "data semi_space");
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

#endif  // LEGACY_GC
