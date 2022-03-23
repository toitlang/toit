// Copyright (c) 2014, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "../../top.h"
#include "../../objects.h"
#include "two_space_heap.h"

namespace toit {

TwoSpaceHeap::TwoSpaceHeap(Program* program)
    : program_(program),
      old_space_(new OldSpace(program, this)),
      unused_semispace_(new SemiSpace(program, Space::CANNOT_RESIZE, NEW_SPACE_PAGE, 0)) {
  semi_space_ = new SemiSpace(program, Space::CANNOT_RESIZE, NEW_SPACE_PAGE, 0);
  semispace_size_ = TOIT_PAGE_SIZE;
  max_size_ = 256 * TOIT_PAGE_SIZE;
}

bool TwoSpaceHeap::initialize() {
  Chunk* chunk = ObjectMemory::allocate_chunk(semi_space_, semispace_size_);
  if (chunk == NULL) return false;
  Chunk* unused_chunk =
      ObjectMemory::allocate_chunk(unused_semispace_, semispace_size_);
  if (unused_chunk == NULL) {
    ObjectMemory::free_chunk(chunk);
    return false;
  }
  semi_space_->append(chunk);
  semi_space_->update_base_and_limit(chunk, chunk->start());
  unused_semispace_->append(unused_chunk);
  water_mark_ = chunk->start();
  return true;
}

TwoSpaceHeap::~TwoSpaceHeap() {
  // We do this before starting to destroy the heap, because the callbacks can
  // trigger calls that assume the heap is still working.
  // TODO(erik): Call all finalizers.
  delete unused_semispace_;
  delete old_space_;
  delete semi_space_;
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
  semi_space_ = unused_semispace_;
  unused_semispace_ = temp;
  water_mark_ = semi_space_->top();
}

SemiSpace* TwoSpaceHeap::take_space() {
  SemiSpace* result = semi_space_;
  semi_space_ = NULL;
  return result;
}

template <class SomeSpace>
HeapObject* GenerationalScavengeVisitor::clone_in_to_space(Program* program, HeapObject* original, SomeSpace* to) {
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

void GenerationalScavengeVisitor::do_roots(Object** start, int count) {
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
        HeapObject* moved_object = clone_in_to_space(program_, old_object, old_);
        // The old space may fill up.  This is a bad moment for a GC, so we
        // promote to the to-space instead.
        if (moved_object == NULL) {
          trigger_old_space_gc_ = true;
          moved_object = clone_in_to_space(program_, old_object, to_);
          *record_ = GcMetadata::NEW_SPACE_POINTERS;
        }
        *p = moved_object;
      } else {
        *p = clone_in_to_space(program_, old_object, to_);
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

void Program::CollectNewSpace() {
  HeapUsage usage_before;

  TwoSpaceHeap* data_heap = process_heap();

  SemiSpace* from = data_heap->space();
  OldSpace* old = data_heap->old_space();

  if (data_heap->HasEmptyNewSpace()) {
    CollectOldSpaceIfNeeded(false);
    return;
  }

  old->Flush();
  from->Flush();

#ifdef DEBUG
  if (Flags::validate_heaps) old->Verify();
#endif

  if (Flags::print_heap_statistics) {
    GetHeapUsage(data_heap, &usage_before);
  }

  SemiSpace* to = data_heap->unused_space();

  uword old_used = old->Used();

  to->set_used(0);
  // Allocate from start of to-space..
  to->UpdateBaseAndLimit(to->chunk(), to->chunk()->start());

  GenerationalScavengeVisitor visitor(data_heap);
  to->StartScavenge();
  old->StartScavenge();

  IterateSharedHeapRoots(&visitor);

  old->VisitRememberedSet(&visitor);

  bool work_found = true;
  while (work_found) {
    work_found = to->CompleteScavengeGenerational(&visitor);
    work_found |= old->CompleteScavengeGenerational(&visitor);
  }
  old->EndScavenge();

  from->ProcessWeakPointers(to, old);

  for (auto process : process_list_) {
    process->set_ports(Port::CleanupPorts(from, process->ports()));
  }

  // Second space argument is used to size the new-space.
  data_heap->SwapSemiSpaces();

  if (Flags::print_heap_statistics) {
    HeapUsage usage_after;
    GetHeapUsage(data_heap, &usage_after);
    PrintProcessGCInfo(&usage_before, &usage_after);
  }

#ifdef DEBUG
  if (Flags::validate_heaps) old->Verify();
#endif

  ASSERT(from->Used() >= to->Used());
  // Find out how much garbage was found.
  word progress = (from->Used() - to->Used()) - (old->Used() - old_used);
  // There's a little overhead when allocating in old space which was not there
  // in new space, so we might overstate the number of promoted bytes a little,
  // which could result in an understatement of the garbage found, even to make
  // it negative.
  if (progress > 0) {
    old->ReportNewSpaceProgress(progress);
  }
  CollectOldSpaceIfNeeded(visitor.trigger_old_space_gc());
  UpdateStackLimits();
}

void Program::CollectOldSpace() {
  if (Flags::validate_heaps) {
    ValidateHeapsAreConsistent();
  }

  SharedHeapUsage usage_before;
  if (Flags::print_heap_statistics) {
    GetSharedHeapUsage(process_heap(), &usage_before);
  }

  PerformSharedGarbageCollection();

  if (Flags::print_heap_statistics) {
    SharedHeapUsage usage_after;
    GetSharedHeapUsage(process_heap(), &usage_after);
    PrintProgramGCInfo(&usage_before, &usage_after);
  }

  if (Flags::validate_heaps) {
    ValidateHeapsAreConsistent();
  }
}

void Program::PerformSharedGarbageCollection() {
  // Mark all reachable objects.  We mark all live objects in new-space too, to
  // detect liveness paths that go through new-space, but we just clear the
  // mark bits afterwards.  Dead objects in new-space are only cleared in a
  // new-space GC (scavenge).
  TwoSpaceHeap* heap = process_heap();
  OldSpace* old_space = heap->old_space();
  SemiSpace* new_space = heap->space();
  MarkingStack stack;
  MarkingVisitor marking_visitor(new_space, &stack);

  IterateSharedHeapRoots(&marking_visitor);

  stack.Process(&marking_visitor, old_space, new_space);

  if (old_space->compacting()) {
    // If the last GC was compacting we don't have fragmentation, so it
    // is fair to evaluate if we are making progress or just doing
    // pointless GCs.
    old_space->EvaluatePointlessness();
    old_space->clear_hard_limit_hit();
    // Do a non-compacting GC this time for speed.
    SweepSharedHeap();
  } else {
    // Last GC was sweeping, so we do a compaction this time to avoid
    // fragmentation.
    old_space->clear_hard_limit_hit();
    CompactSharedHeap();
  }

  heap->AdjustOldAllocationBudget();

#ifdef DEBUG
  if (Flags::validate_heaps) old_space->Verify();
#endif
}

void Program::SweepSharedHeap() {
  TwoSpaceHeap* heap = process_heap();
  OldSpace* old_space = heap->old_space();
  SemiSpace* new_space = heap->space();

  old_space->set_compacting(false);

  old_space->ProcessWeakPointers();

  for (auto process : process_list_) {
    process->set_ports(Port::CleanupPorts(old_space, process->ports()));
  }

  // Sweep over the old-space and rebuild the freelist.
  SweepingVisitor sweeping_visitor(old_space);
  old_space->IterateObjects(&sweeping_visitor);

  // These are only needed during the mark phase, we can clear them without
  // looking at them.
  new_space->ClearMarkBits();

  for (auto process : process_list_) process->UpdateStackLimit();

  uword used_after = sweeping_visitor.used();
  old_space->set_used(used_after);
  old_space->set_used_after_last_gc(used_after);
  heap->AdjustOldAllocationBudget();
}

void Program::CompactSharedHeap() {
  TwoSpaceHeap* heap = process_heap();
  OldSpace* old_space = heap->old_space();
  SemiSpace* new_space = heap->space();

  old_space->set_compacting(true);

  old_space->ComputeCompactionDestinations();

  old_space->ClearFreeList();

  // Weak processing when the destination addresses have been calculated, but
  // before they are moved (which ruins the liveness data).
  old_space->ProcessWeakPointers();

  for (auto process : process_list_) {
    process->set_ports(Port::CleanupPorts(old_space, process->ports()));
  }

  old_space->ZapObjectStarts();

  FixPointersVisitor fix;
  CompactingVisitor compacting_visitor(old_space, &fix);
  old_space->IterateObjects(&compacting_visitor);
  uword used_after = compacting_visitor.used();
  old_space->set_used(used_after);
  old_space->set_used_after_last_gc(used_after);
  fix.set_source_address(0);

  HeapObjectPointerVisitor new_space_visitor(&fix);
  new_space->IterateObjects(&new_space_visitor);

  IterateSharedHeapRoots(&fix);

  new_space->ClearMarkBits();
  old_space->ClearMarkBits();
  old_space->MarkChunkEndsFree();
}

#endif

#ifdef DEBUG
void TwoSpaceHeap::find(uword word) {
  semi_space_->find(word, "data semispace");
  unused_semispace_->find(word, "unused semispace");
  old_space_->find(word, "oldspace");
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
