// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "gc_metadata.h"
#include "object_memory.h"
#include "two_space_heap.h"

#include "../../heap.h"
#include "../../objects.h"

#include "../../objects_inline.h"

namespace toit {

class Program;

static void write_sentinel_at(uword address) {
  ASSERT(sizeof(Object*) == SENTINEL_SIZE);
  *reinterpret_cast<Object**>(address) = chunk_end_sentinel();
}

Space::Space(Program* program, Space::Resizing resizeable, PageType page_type)
    : program_(program),
      used_(0),
      top_(0),
      limit_(0),
      allocation_budget_(0),
      no_allocation_failure_nesting_(0),
      resizeable_(resizeable == CAN_RESIZE),
      page_type_(page_type) {}

SemiSpace::SemiSpace(Program* program, Space::Resizing resizeable, PageType page_type,
                     uword maximum_initial_size)
    : Space(program, resizeable, page_type) {
  if (resizeable_ && maximum_initial_size > 0) {
    uword size = Utils::min(
        Utils::round_up(maximum_initial_size, TOIT_PAGE_SIZE),
        DEFAULT_MAXIMUM_CHUNK_SIZE);
    Chunk* chunk = ObjectMemory::allocate_chunk(this, size);
    if (chunk == null) FATAL("Failed to allocate %d bytes.\n", size);
    append(chunk);
    update_base_and_limit(chunk, chunk->start());
  }
}

bool SemiSpace::is_flushed() {
  if (top_ == 0 && limit_ == 0) return true;
  return has_sentinel_at(top_);
}

void SemiSpace::update_base_and_limit(Chunk* chunk, uword top) {
  ASSERT(is_flushed());
  ASSERT(top >= chunk->start());
  ASSERT(top < chunk->end());

  top_ = top;
  // Always write a sentinel so the scavenger knows where to stop.
  write_sentinel_at(top_);
  limit_ = chunk->end();
  if (top == chunk->start() && GcMetadata::in_metadata_range(top)) {
    GcMetadata::initialize_starts_for_chunk(chunk);
  }
}

void SemiSpace::flush() {
  if (!is_empty()) {
    // Set sentinel at allocation end.
    ASSERT(top_ < limit_);
    write_sentinel_at(top_);
  }
}

HeapObject* SemiSpace::new_location(HeapObject* old_location) {
  ASSERT(includes(old_location->_raw()));
  return old_location->forwarding_address();
}

bool SemiSpace::is_alive(HeapObject* old_location) {
  ASSERT(includes(old_location->_raw()));
  return old_location->has_forwarding_address();
}

void Space::append(Chunk* chunk) {
  ASSERT(chunk->owner() == this);
  // Insert chunk in increasing address order in the list.  This is
  // useful for the partial compactor.
  if (!chunk_list_.insert_before(chunk, [&chunk](Chunk* it) { return it->start() > chunk->start(); })) {
    chunk_list_.append(chunk);
  }
}

void SemiSpace::append(Chunk* chunk) {
  ASSERT(chunk->owner() == this);
  if (!is_empty()) {
    // Update the accounting.
    used_ += top() - chunk_list_.last()->start();
  }
  // For the semispaces, we always append the chunk to the end of the space.
  // This ensures that when iterating over newly promoted objects during a
  // scavenge we will see the objects newly promoted to newly allocated chunks.
  chunk_list_.append(chunk);
}

uword SemiSpace::try_allocate(uword size) {
  // Make sure there is room for chunk end sentinel by using > instead of >=.
  // Use this ordering of the comparison to avoid very large allocations
  // turning into 'successful' allocations of negative size.
  if (limit_ - top_ > size) {
    uword result = top_;
    top_ += size;
    // Always write a sentinel so the scavenger knows where to stop.
    write_sentinel_at(top_);
    return result;
  }

  if (!is_empty()) {
    // Make the last chunk consistent with a sentinel.
    flush();
  }

  return 0;
}

uword SemiSpace::allocate_in_new_chunk(uword size) {
  // Allocate new chunk that is big enough to fit the object.
  uword default_chunk_size = get_default_chunk_size(used());
  uword chunk_size =
      size >= default_chunk_size
          ? (size + WORD_SIZE)  // Make sure there is room for sentinel.
          : default_chunk_size;

  Chunk* chunk = ObjectMemory::allocate_chunk(this, chunk_size);
  if (chunk != null) {
    // Link it into the space.
    append(chunk);

    // Update limits.
    allocation_budget_ -= chunk->size();
    update_base_and_limit(chunk, chunk->start());

    // Allocate.
    uword result = try_allocate(size);
    if (result != 0) return result;
  }
  return 0;
}

uword SemiSpace::allocate(uword size) {
  ASSERT(size >= HeapObject::SIZE);
  ASSERT(Utils::is_aligned(size, WORD_SIZE));

  uword result = try_allocate(size);
  if (result != 0) return result;

  if (!in_no_allocation_failure_scope() && needs_garbage_collection()) return 0;

  return allocate_in_new_chunk(size);
}

uword SemiSpace::used() {
  if (is_empty()) return used_;
  return used_ + (top() - chunk_list_.last()->start());
}

// Called multiple times until there is no more work.  Finds objects moved to
// the to-space and traverses them to find and fix more new-space pointers.
bool SemiSpace::complete_scavenge_generational(GenerationalScavengeVisitor* visitor) {
  bool found_work = false;
  // No need to update remembered set for semispace->semispace pointers.
  uint8 dummy;
  visitor->set_record_new_space_pointers(&dummy);

  for (auto chunk : chunk_list_) {
    uword current = chunk->scavenge_pointer();
    while (!has_sentinel_at(current)) {
      found_work = true;
      HeapObject* object = HeapObject::from_address(current);
      object->roots_do(program_, visitor);

      current += object->size(program_);
    }
    // Set up the already-scanned pointer for next round.
    chunk->set_scavenge_pointer(current);
  }

  return found_work;
}

void SemiSpace::process_weak_pointers(SemiSpace* to_space, OldSpace* old_space) {
  // TODO(erik): Process finalizers.
}

}  // namespace toit
