// Copyright (c) 2022, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "gc_metadata.h"
#include "object_memory.h"
#include "two_space_heap.h"

#include "../../top.h"

#ifndef LEGACY_GC

#include "../../heap.h"
#include "../../objects.h"

namespace toit {

class Program;

static void write_sentinel_at(uword address) {
  ASSERT(sizeof(Object*) == SENTINEL_SIZE);
  *reinterpret_cast<Object**>(address) = chunk_end_sentinel();
}

Space::Space(Program* program, Space::Resizing resizeable, PageType page_type)
    : program_(program),
      page_type_(page_type) {}

SemiSpace::SemiSpace(Program* program, Chunk* chunk)
    : Space(program, CANNOT_RESIZE, NEW_SPACE_PAGE) {
  if (!chunk) return;
  append(chunk);
  update_base_and_limit(chunk, chunk->start());
  chunk->set_owner(this);
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

#ifdef DEBUG
void SemiSpace::validate() {
  // Iterate all objects, checking their size makes sense.
  for (auto chunk : chunk_list_) {
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::from_address(current);
      current += object->size(program_);
    }
    ASSERT(current < chunk->end());
  }
}

void Space::validate_before_mark_sweep(PageType expected_page_type, bool object_starts_should_be_clear) {
  for (auto chunk : chunk_list_) {
    uword start = chunk->start();
    uword end = chunk->end();

    if (object_starts_should_be_clear) {
      // Verify that the object starts table contains no entries (they are added as
      // needed if there is a mark stack overflow).
      uint8* starts = GcMetadata::starts_for(start);
      uint8* end_of_starts = GcMetadata::starts_for(end);
      for (uint8* p = starts; p < end_of_starts; p++) {
        ASSERT(*p == GcMetadata::NO_OBJECT_START);
        USE(p);
      }
    }

    // Verify the overflow bits are not already set before there is a mark
    // stack overflow.
    uint8* overflow = GcMetadata::overflow_bits_for(start);
    uint8* end_of_overflow = GcMetadata::overflow_bits_for(end);
    for (uint8* p = overflow; p < end_of_overflow; p++) {
      ASSERT(*p == 0);
      USE(p);
    }

    // Verify the pages have the right type.
    for (uword p = start; p < end; p += TOIT_PAGE_SIZE) {
      PageType type = GcMetadata::get_page_type(p);
      ASSERT(type == expected_page_type);
      USE(type);
    }

    // Verify that no objects are marked before we start marking.
    uint32* mark_bits_end = GcMetadata::mark_bits_for(end);
    for (uint32* p = GcMetadata::mark_bits_for(start); p < mark_bits_end; p++) {
      ASSERT(*p == 0);
      USE(p);
    }
  }
}
#endif

HeapObject* SemiSpace::new_location(HeapObject* old_location) {
  ASSERT(includes(old_location->_raw()));
  return old_location->forwarding_address();
}

bool SemiSpace::is_alive(HeapObject* old_location) {
  // If we are doing a scavenge and are asked whether an old-space object is
  // alive, return true.
  if (!includes(old_location->_raw())) return true;
  return old_location->has_forwarding_address();
}

void Space::append(Chunk* chunk) {
  chunk->set_owner(this);
  // Insert chunk in increasing address order in the list.  This is
  // useful for the partial compactor.
  chunk_list_.insert_before(chunk, [&chunk](Chunk* it) { return it->start() > chunk->start(); });
}

void SemiSpace::append(Chunk* chunk) {
  chunk->set_owner(this);
  // For the semispaces, we always append the chunk to the end of the space.
  // This ensures that when iterating over newly promoted objects during a
  // scavenge we will see the objects newly promoted to newly allocated chunks.
  chunk_list_.append(chunk);
}

uword SemiSpace::allocate(uword size) {
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

uword SemiSpace::used() {
  ASSERT(chunk_list_.first() == chunk_list_.last());
  return (top() - chunk_list_.last()->start());
}

// Called multiple times until there is no more work.  Finds objects moved to
// the to-space and traverses them to find and fix more new-space pointers.
bool SemiSpace::complete_scavenge(ScavengeVisitor* visitor) {
  bool found_work = false;
  // No need to update remembered set for semispace->semispace pointers.
  visitor->set_record_to_dummy_address();

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

}  // namespace toit

#endif  // LEGACY_GC
