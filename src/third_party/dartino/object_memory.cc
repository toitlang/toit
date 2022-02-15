// Copyright (c) 2014, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "src/vm/object_memory.h"

#include <stdlib.h>
#include <stdio.h>

#include "src/shared/assert.h"
#include "src/shared/platform.h"
#include "src/shared/utils.h"

#include "src/vm/frame.h"
#include "src/vm/heap.h"
#include "src/vm/mark_sweep.h"
#include "src/vm/object.h"

namespace dartino {

Chunk::Chunk(Space* owner, uword start, uword size, bool external)
      : owner_(owner),
        start_(start),
        end_(start + size),
        external_(external),
        scavenge_pointer_(start_) {
  if (GCMetadata::InMetadataRange(start)) {
    GCMetadata::InitializeOverflowBitsForChunk(this);
  }
}

Chunk::~Chunk() {
  // If the memory for this chunk is external we leave it alone
  // and let the embedder deallocate it.
  if (is_external()) return;
  GCMetadata::MarkPagesForChunk(this, kUnknownSpacePage);
  Platform::FreePages(reinterpret_cast<void*>(start_), size());
}

Space::~Space() {
  WeakPointer::ForceCallbacks(&weak_pointers_);
  FreeAllChunks();
}

void Space::FreeAllChunks() {
  for (auto it = chunk_list_.Begin(); it != chunk_list_.End();) {
    Chunk* current = *it;
    it = chunk_list_.Erase(it);
    ObjectMemory::FreeChunk(current);
  }
  top_ = limit_ = 0;
}

uword Space::Size() {
  uword result = 0;
  for (auto chunk : chunk_list_) result += chunk->size();
  ASSERT(Used() <= result);
  return result;
}

word Space::OffsetOf(HeapObject* object) {
  uword address = object->address();
  uword start = chunk_list_.First()->start();

  // Make sure the space consists of exactly one chunk!
  ASSERT(chunk_list_.First() == chunk_list_.Last());
  ASSERT(chunk_list_.First()->Includes(address));
  ASSERT(start <= address);

  return address - start;
}

HeapObject *Space::ObjectAtOffset(word offset) {
  uword start = chunk_list_.First()->start();
  uword address = offset + start;

  // Make sure the space consists of exactly one chunk!
  ASSERT(chunk_list_.First() == chunk_list_.Last());

  ASSERT(chunk_list_.First()->Includes(address));
  ASSERT(start <= address);

  return HeapObject::FromAddress(address);
}

void Space::AdjustAllocationBudget(uword used_outside_space) {
  uword used = Used() + used_outside_space;
  // Allow heap size to double (but we may hit maximum heap size limits before
  // that).
  allocation_budget_ = used + Platform::kPageSize;
}

void Space::IncreaseAllocationBudget(uword size) { allocation_budget_ += size; }

void Space::DecreaseAllocationBudget(uword size) { allocation_budget_ -= size; }

void Space::SetAllocationBudget(word new_budget) {
  allocation_budget_ = Utils::Maximum(
      static_cast<word>(DefaultChunkSize(new_budget)), new_budget);
}

void Space::IterateOverflowedObjects(PointerVisitor* visitor,
                                     MarkingStack* stack) {
  static_assert(
      Platform::kPageSize % (1 << GCMetadata::kCardSizeInBitsLog2) == 0,
      "MarkStackOverflowBytesMustCoverAFractionOfAPage");

  for (auto chunk : chunk_list_) {
    uint8* bits = GCMetadata::OverflowBitsFor(chunk->start());
    uint8* bits_limit = GCMetadata::OverflowBitsFor(chunk->end());
    uword card = chunk->start();
    for (; bits < bits_limit; bits++) {
      for (int i = 0; i < 8; i++, card += GCMetadata::kCardSize) {
        // Skip cards 8 at a time if they are clear.
        if (*bits == 0) {
          card += GCMetadata::kCardSize * (8 - i);
          break;
        }
        if ((*bits & (1 << i)) != 0) {
          // Clear the bit immediately, since the mark stack could overflow and
          // a different object in this card could fail to push, setting the
          // bit again.
          *bits &= ~(1 << i);
          uint8 start = *GCMetadata::StartsFor(card);
          ASSERT(start != GCMetadata::kNoObjectStart);
          uword object_address = (card | start);
          for (HeapObject* object;
               object_address < card + GCMetadata::kCardSize &&
               !has_sentinel_at(object_address);
               object_address += object->Size()) {
            object = HeapObject::FromAddress(object_address);
            if (GCMetadata::IsGrey(object)) {
              GCMetadata::MarkAll(object, object->Size());
              object->IteratePointers(visitor);
            }
          }
        }
      }
      stack->Empty(visitor);
    }
  }
}

void Space::IterateObjects(HeapObjectVisitor* visitor) {
  if (is_empty()) return;
  Flush();
  for (auto chunk : chunk_list_) {
    visitor->ChunkStart(chunk);
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::FromAddress(current);
      word size = visitor->Visit(object);
      ASSERT(size > 0);
      current += size;
    }
    visitor->ChunkEnd(chunk, current);
  }
}

void SemiSpace::CompleteScavenge(PointerVisitor* visitor) {
  Flush();
  for (auto chunk : chunk_list_) {
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::FromAddress(current);
      object->IteratePointers(visitor);
      current += object->Size();
      Flush();
    }
  }
}

void Space::ClearMarkBits() {
  Flush();
  for (auto chunk : chunk_list_) GCMetadata::ClearMarkBitsFor(chunk);
}

bool Space::Includes(uword address) {
  for (auto chunk : chunk_list_)
    if (chunk->Includes(address)) return true;
  return false;
}

#ifdef DEBUG
void Space::Find(uword w, const char* name) {
  for (auto chunk : chunk_list_) chunk->Find(w, name);
}
#endif

void Space::CompleteTransformations(PointerVisitor* visitor) {
  Flush();
  for (auto chunk : chunk_list_) {
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::FromAddress(current);
      if (object->HasForwardingAddress()) {
        current += Instance::kSize;
      } else {
        object->IteratePointers(visitor);
        current += object->Size();
      }
      Flush();
    }
  }
}

Atomic<uword> ObjectMemory::allocated_;

void ObjectMemory::Setup() {
  allocated_ = 0;
  GCMetadata::Setup();
}

void ObjectMemory::TearDown() {
  GCMetadata::TearDown();
}

#ifdef DEBUG
void Chunk::Scramble() {
  void* p = reinterpret_cast<void*>(start_);
  memset(p, 0xab, size());
}

void Chunk::Find(uword word, const char* name) {
  if (word >= start_ && word < end_) {
    fprintf(stderr, "0x%08zx is inside the 0x%08zx-0x%08zx chunk in %s\n",
            static_cast<size_t>(word), static_cast<size_t>(start_),
            static_cast<size_t>(end_), name);
  }
  for (uword current = start_; current < end_; current += 4) {
    if (*reinterpret_cast<unsigned*>(current) == (unsigned)word) {
      fprintf(stderr, "Found 0x%08zx in %s at 0x%08zx\n",
              static_cast<size_t>(word), name, static_cast<size_t>(current));
    }
  }
}
#endif

Chunk* ObjectMemory::AllocateChunk(Space* owner, uword size) {
  ASSERT(owner != NULL);

  size = Utils::RoundUp(size, Platform::kPageSize);
  void* memory =
      Platform::AllocatePages(size, GCMetadata::heap_allocation_arena());
  uword lowest = GCMetadata::lowest_old_space_address();
  USE(lowest);
  if (memory == NULL) return NULL;
  ASSERT(reinterpret_cast<uword>(memory) >= lowest);
  ASSERT(reinterpret_cast<uword>(memory) - lowest + size <=
         GCMetadata::heap_extent());

  uword base = reinterpret_cast<uword>(memory);
  Chunk* chunk = new Chunk(owner, base, size);

  ASSERT(base == Utils::RoundUp(base, Platform::kPageSize));
  ASSERT(size == Utils::RoundUp(size, Platform::kPageSize));

#ifdef DEBUG
  chunk->Scramble();
#endif
  GCMetadata::MarkPagesForChunk(chunk, owner->page_type());
  allocated_ += size;
  return chunk;
}

Chunk* ObjectMemory::CreateFixedChunk(Space* owner, void* memory, uword size) {
  ASSERT(owner != NULL);
  ASSERT(size == Utils::RoundUp(size, Platform::kPageSize));

  uword base = reinterpret_cast<uword>(memory);
  ASSERT(base % Platform::kPageSize == 0);

  Chunk* chunk = new Chunk(owner, base, size, true);
  GCMetadata::MarkPagesForChunk(chunk, owner->page_type());
  return chunk;
}

void ObjectMemory::FreeChunk(Chunk* chunk) {
#ifdef DEBUG
  // Do not touch external memory. It might be read-only.
  if (!chunk->is_external()) chunk->Scramble();
#endif
  allocated_ -= chunk->size();
  delete chunk;
}

// Put free-list entries on the objects that are now dead.
void OldSpace::RebuildAfterTransformations() {
  for (auto chunk : chunk_list_) {
    uword free_start = 0;
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::FromAddress(current);
      if (object->HasForwardingAddress()) {
        if (free_start == 0) free_start = current;
        current += Instance::kSize;
        while (HeapObject::FromAddress(current)->IsFiller()) {
          current += kPointerSize;
        }
      } else {
        if (free_start != 0) {
          free_list_->AddChunk(free_start, current - free_start);
          free_start = 0;
        }
        current += object->Size();
      }
    }
  }
}

// Put one-word-fillers on the dead objects so it is still iterable.
void SemiSpace::RebuildAfterTransformations() {
  for (auto chunk : chunk_list_) {
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::FromAddress(current);
      if (object->HasForwardingAddress()) {
        for (int i = 0; i < Instance::kSize; i += kPointerSize) {
          *reinterpret_cast<Object**>(current + i) =
              StaticClassStructures::one_word_filler_class();
        }
        current += Instance::kSize;
      } else {
        current += object->Size();
      }
    }
  }
}

#ifdef DEBUG
NoAllocationScope::NoAllocationScope(Heap* heap) : heap_(heap) {
  heap->IncrementNoAllocation();
}

NoAllocationScope::~NoAllocationScope() { heap_->DecrementNoAllocation(); }
#endif

}  // namespace dartino
