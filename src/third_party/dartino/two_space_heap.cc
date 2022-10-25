// Copyright (c) 2022, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "../../top.h"

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

word TwoSpaceHeap::max_external_allocation() {
  return process_heap_->max_external_allocation();
}

Process* TwoSpaceHeap::process() {
  return process_heap_->owner();
}

HeapObject* TwoSpaceHeap::allocate(uword size) {
  uword result = semi_space_.allocate(size);
  if (result == 0) {
    return new_space_allocation_failure(size);
  }
  return HeapObject::from_address(result);
}

HeapObject* TwoSpaceHeap::new_space_allocation_failure(uword size) {
  if (!process_heap_->has_limit()) {
    // When we are rerunning a primitive after a GC we don't want to
    // trigger a new GC unless we abolutely have to, so we allow allocation
    // directly into old-space.  We recognize this situation by there not
    // being an allocation limit (it is installed when the primitive
    // completes).
    uword result = old_space_.allocate(size);
    if (result != 0) {
      // The code that populates newly allocated objects assumes that they
      // are in new space and does not have a write barrier.  We mark the
      // object dirty immediately, so it is checked by the next GC.
      GcMetadata::insert_into_remembered_set(result);
      return HeapObject::from_address(result);
    }
  }
  return null;
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

GcType TwoSpaceHeap::collect_new_space(bool try_hard) {
  SemiSpace* from = new_space();

  uint64 start = OS::get_monotonic_time();

  // Might get set during scavenge if we fail to promote to a full old-space
  // that can't be expanded.
  malloc_failed_ = false;

  total_bytes_allocated_ += from->used();

  if (has_empty_new_space()) {
    if (Flags::tracegc) {
      printf("Old-space-only GC (try_hard = %s)\n", try_hard ? "true" : "false");
    }
    return collect_old_space_if_needed(try_hard, try_hard);
  }

  old_space()->flush();
  from->flush();

#ifdef TOIT_DEBUG
  if (Flags::validate_heap) validate();
#endif

  uword old_used = old_space()->used();
  word old_external = process_heap_->external_memory();
  word from_used;
  word to_used;
  bool trigger_old_space_gc;

  if (!ObjectMemory::spare_chunk_mutex()) FATAL("ObjectMemory::set_up() not called");

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
    int o = old_used;
    int oe = old_external;
    int ne = process_heap_->external_memory();
    int old = old_space()->used();

    uword overhead = old_space()->size() - old;

    char overhead_buffer[40];
    if (overhead < TOIT_PAGE_SIZE) {
      overhead_buffer[0] = '\0';
    } else {
      overhead_buffer[sizeof(overhead_buffer) - 1] = '\0';
      snprintf(overhead_buffer, sizeof(overhead_buffer) - 1, " +%dk overhead", static_cast<int>(overhead) >> 10);
    }

    char external_buffer[40];
    external_buffer[sizeof(external_buffer) - 1] = '\0';
    if (oe >> 10 == ne >> 10) {
      if (oe >> 10 == 0) {
        external_buffer[0] = '\0';
      } else {
        snprintf(external_buffer, sizeof(external_buffer) - 1, ", external %dk", oe >> 10);
      }
    } else {
      snprintf(external_buffer, sizeof(external_buffer) - 1, ", external %dk->%dk",
          oe >> 10,
          ne >> 10);
    }

    printf("%p Scavenge: %d%c->%d%c (old-gen %d%c->%d%c%s%s) %dus\n",
        process_heap_->owner(),
        (f >> 10) ? (f >> 10) : f,
        (f >> 10) ? 'k' : 'b',
        (t >> 10) ? (t >> 10) : t,
        (t >> 10) ? 'k' : 'b',
        (o >> 10) ? (o >> 10) : o,
        (o >> 10) ? 'k' : 'b',
        (old >> 10) ? (old >> 10) : old,
        (old >> 10) ? 'k' : 'b',
        overhead_buffer,
        external_buffer,
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

  return collect_old_space_if_needed(try_hard, trigger_old_space_gc);
}

uword TwoSpaceHeap::total_bytes_allocated() const {
  uword result = total_bytes_allocated_;
  result += new_space()->used();
  return result;
}

GcType TwoSpaceHeap::collect_old_space_if_needed(bool force_compact, bool force) {
#ifdef TOIT_DEBUG
  if (Flags::validate_heap) {
    validate();
    old_space()->validate_before_mark_sweep(OLD_SPACE_PAGE, false);
    new_space()->validate_before_mark_sweep(NEW_SPACE_PAGE, true);
  }
#endif
  if (!force && !force_compact && !old_space()->needs_garbage_collection()) {
    return NEW_SPACE_GC;
  }

  ASSERT(old_space()->is_flushed());
  ASSERT(new_space()->is_flushed());
  return collect_old_space(force_compact);
}

#ifdef TOIT_DEBUG
void TwoSpaceHeap::validate() {
  new_space()->validate();
  old_space()->validate();
}
#endif

GcType TwoSpaceHeap::collect_old_space(bool force_compact) {

  uint64 start = OS::get_monotonic_time();
  uword old_used = old_space()->used();
  uword old_external = process_heap_->external_memory();

  bool compacted = perform_garbage_collection(force_compact);

  if (Flags::tracegc) {
    uint64 end = OS::get_monotonic_time();
    int f = old_used;
    int t = old_space()->used();
    uword overhead = old_space()->size() - t;
    int oe = old_external;
    int ne = process_heap_->external_memory();

    char overhead_buffer[40];
    if (overhead < TOIT_PAGE_SIZE) {
      overhead_buffer[0] = '\0';
    } else {
      overhead_buffer[sizeof(overhead_buffer) - 1] = '\0';
      snprintf(overhead_buffer, sizeof(overhead_buffer) - 1, " +%dk overhead", static_cast<int>(overhead) >> 10);
    }

    char external_buffer[40];
    external_buffer[sizeof(external_buffer) - 1] = '\0';
    if (oe >> 10 == ne >> 10) {
      if (oe >> 10 == 0) {
        external_buffer[0] = '\0';
      } else {
        snprintf(external_buffer, sizeof(external_buffer) - 1, " (external %dk)", oe >> 10);
      }
    } else {
      snprintf(external_buffer, sizeof(external_buffer) - 1, " (external %dk->%dk)",
          oe >> 10,
          ne >> 10);
    }

    printf("%p Mark-sweep%s: %d%c->%d%c%s%s %dus\n",
        process_heap_->owner(),
        compacted ? "-compact" : "",
        (f >> 10) ? (f >> 10) : f,
        (f >> 10) ? 'k' : 'b',
        (t >> 10) ? (t >> 10) : t,
        (t >> 10) ? 'k' : 'b',
        overhead_buffer,
        external_buffer,
        static_cast<int>(end - start));
  }

  old_space()->set_promotion_failed(false);

#ifdef TOIT_DEBUG
  if (Flags::validate_heap) {
    validate();
  }
#endif

  return compacted ? COMPACTING_GC : FULL_GC;
}

bool TwoSpaceHeap::perform_garbage_collection(bool force_compact) {
  // Mark all reachable objects.  We mark all live objects in new-space too, to
  // detect liveness paths that go through new-space, but we just clear the
  // mark bits afterwards.  Dead objects in new-space are only cleared in a
  // new-space GC (scavenge).
  SemiSpace* semi_space = new_space();
  MarkingStack stack(program_);
  MarkingVisitor marking_visitor(semi_space, &stack);

  process_heap_->iterate_roots(&marking_visitor);

  stack.process(&marking_visitor, old_space(), semi_space);

  process_heap_->process_registered_finalizers(&marking_visitor, old_space());

  stack.process(&marking_visitor, old_space(), semi_space);

  process_heap_->process_registered_vm_finalizers(&marking_visitor, old_space());

  stack.process(&marking_visitor, old_space(), semi_space);

  word regained_by_compacting = old_space()->compute_compaction_destinations();

  bool compact = force_compact || regained_by_compacting > 0;

  if (compact) {
    // We can reclaim some memory by compacting.
    compact_heap();
  } else {
    // Do a non-compacting GC this time for speed.
    sweep_heap();
  }

#ifdef TOIT_DEBUG
  if (Flags::validate_heap) validate();
#endif

  return compact;
}

void TwoSpaceHeap::sweep_heap() {
  SemiSpace* semi_space = new_space();

  old_space()->set_compacting(false);

  // Sweep over the old-space and rebuild the freelist.
  uword used_after = old_space()->sweep();

  // These are only needed during the mark phase, we can clear them without
  // looking at them.
  semi_space->clear_mark_bits();

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
  SemiSpace* semi_space = new_space();

  old_space()->set_compacting(true);

  old_space()->clear_free_list();

  old_space()->zap_object_starts();

  FixPointersVisitor fix;
  CompactingVisitor compacting_visitor(program_, old_space(), &fix);
  old_space()->iterate_objects(&compacting_visitor);
  uword used_after = compacting_visitor.used();
  old_space()->set_used(used_after);
  old_space()->set_used_after_last_gc(used_after);

  HeapObjectPointerVisitor new_space_visitor(program_, &fix);
  semi_space->iterate_objects(&new_space_visitor);

  process_heap_->iterate_roots(&fix);
  // At this point dead objects have been cleared out of the finalizer lists.
  EverythingIsAlive yes;
  process_heap_->process_registered_finalizers(&fix, &yes);
  process_heap_->process_registered_vm_finalizers(&fix, &yes);

  semi_space->clear_mark_bits();
  old_space()->clear_mark_bits();
  old_space()->mark_chunk_ends_free();
}

#ifdef TOIT_DEBUG
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
#endif  // TOIT_DEBUG

}  // namespace toit
