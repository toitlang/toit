// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "src/vm/object_memory.h"

#include "src/vm/heap.h"
#include "src/vm/object.h"

namespace dartino {

static void WriteSentinelAt(uword address) {
  ASSERT(sizeof(Object*) == kSentinelSize);
  *reinterpret_cast<Object**>(address) = chunk_end_sentinel();
}

Space::Space(Space::Resizing resizeable, PageType page_type)
    : used_(0),
      top_(0),
      limit_(0),
      allocation_budget_(0),
      no_allocation_failure_nesting_(0),
      resizeable_(resizeable == kCanResize),
      page_type_(page_type) {}

SemiSpace::SemiSpace(Space::Resizing resizeable, PageType page_type,
                     uword maximum_initial_size)
    : Space(resizeable, page_type) {
  if (resizeable_ && maximum_initial_size > 0) {
    uword size = Utils::Minimum(
        Utils::RoundUp(maximum_initial_size, Platform::kPageSize),
        kDefaultMaximumChunkSize);
    Chunk* chunk = ObjectMemory::AllocateChunk(this, size);
    if (chunk == NULL) FATAL1("Failed to allocate %d bytes.\n", size);
    Append(chunk);
    UpdateBaseAndLimit(chunk, chunk->start());
  }
}

bool SemiSpace::IsFlushed() {
  if (top_ == 0 && limit_ == 0) return true;
  return HasSentinelAt(top_);
}

void SemiSpace::UpdateBaseAndLimit(Chunk* chunk, uword top) {
  ASSERT(IsFlushed());
  ASSERT(top >= chunk->start());
  ASSERT(top < chunk->end());

  top_ = top;
  // Always write a sentinel so the scavenger knows where to stop.
  WriteSentinelAt(top_);
  limit_ = chunk->end();
  if (top == chunk->start() && GCMetadata::InMetadataRange(top)) {
    GCMetadata::InitializeStartsForChunk(chunk);
  }
}

void SemiSpace::Flush() {
  if (!is_empty()) {
    // Set sentinel at allocation end.
    ASSERT(top_ < limit_);
    WriteSentinelAt(top_);
  }
}

HeapObject* SemiSpace::NewLocation(HeapObject* old_location) {
  ASSERT(Includes(old_location->address()));
  return old_location->forwarding_address();
}

bool SemiSpace::IsAlive(HeapObject* old_location) {
  ASSERT(Includes(old_location->address()));
  return old_location->HasForwardingAddress();
}

void Space::Append(Chunk* chunk) {
  ASSERT(chunk->owner() == this);
  // Insert chunk in increasing address order in the list.  This is
  // useful for the partial compactor.
  uword start = 0;
  for (auto it = chunk_list_.Begin(); it != chunk_list_.End(); ++it) {
    ASSERT(it->start() > start);
    start = it->start();
    if (start > chunk->start()) {
      chunk_list_.Insert(it, chunk);
      return;
    }
  }
  chunk_list_.Append(chunk);
}

void SemiSpace::Append(Chunk* chunk) {
  ASSERT(chunk->owner() == this);
  if (!is_empty()) {
    // Update the accounting.
    used_ += top() - chunk_list_.Last()->start();
  }
  // For the semispaces, we always append the chunk to the end of the space.
  // This ensures that when iterating over newly promoted objects during a
  // scavenge we will see the objects newly promoted to newly allocated chunks.
  chunk_list_.Append(chunk);
}

uword SemiSpace::TryAllocate(uword size) {
  // Make sure there is room for chunk end sentinel by using > instead of >=.
  // Use this ordering of the comparison to avoid very large allocations
  // turning into 'successful' allocations of negative size.
  if (limit_ - top_ > size) {
    uword result = top_;
    top_ += size;
    // Always write a sentinel so the scavenger knows where to stop.
    WriteSentinelAt(top_);
    return result;
  }

  if (!is_empty()) {
    // Make the last chunk consistent with a sentinel.
    Flush();
  }

  return 0;
}

uword SemiSpace::AllocateInNewChunk(uword size) {
  // Allocate new chunk that is big enough to fit the object.
  uword default_chunk_size = DefaultChunkSize(Used());
  uword chunk_size =
      size >= default_chunk_size
          ? (size + kPointerSize)  // Make sure there is room for sentinel.
          : default_chunk_size;

  Chunk* chunk = ObjectMemory::AllocateChunk(this, chunk_size);
  if (chunk != NULL) {
    // Link it into the space.
    Append(chunk);

    // Update limits.
    allocation_budget_ -= chunk->size();
    UpdateBaseAndLimit(chunk, chunk->start());

    // Allocate.
    uword result = TryAllocate(size);
    if (result != 0) return result;
  }
  return 0;
}

uword SemiSpace::Allocate(uword size) {
  ASSERT(size >= HeapObject::kSize);
  ASSERT(Utils::IsAligned(size, kPointerSize));

  uword result = TryAllocate(size);
  if (result != 0) return result;

  if (!in_no_allocation_failure_scope() && needs_garbage_collection()) return 0;

  return AllocateInNewChunk(size);
}

uword SemiSpace::Used() {
  if (is_empty()) return used_;
  return used_ + (top() - chunk_list_.Last()->start());
}

// Called multiple times until there is no more work.  Finds objects moved to
// the to-space and traverses them to find and fix more new-space pointers.
bool SemiSpace::CompleteScavengeGenerational(
    GenerationalScavengeVisitor* visitor) {
  bool found_work = false;
  // No need to update remembered set for semispace->semispace pointers.
  uint8 dummy;
  visitor->set_record_new_space_pointers(&dummy);

  for (auto chunk : chunk_list_) {
    uword current = chunk->scavenge_pointer();
    while (!HasSentinelAt(current)) {
      found_work = true;
      HeapObject* object = HeapObject::FromAddress(current);
      object->IteratePointers(visitor);

      current += object->Size();
    }
    // Set up the already-scanned pointer for next round.
    chunk->set_scavenge_pointer(current);
  }

  return found_work;
}

void SemiSpace::ProcessWeakPointers(SemiSpace* to_space, OldSpace* old_space) {
  ASSERT(this != to_space);  // This should be from-space.
  WeakPointer::ProcessAndMoveSurvivors(&weak_pointers_, this, to_space,
                                       old_space);
}

}  // namespace dartino
