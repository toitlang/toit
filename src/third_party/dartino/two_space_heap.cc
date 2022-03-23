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
