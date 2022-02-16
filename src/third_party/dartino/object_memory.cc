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
  if (GCMetadata::in_metadata_range(start)) {
    GCMetadata::initialize_overflow_bits_for_chunk(this);
  }
}

Chunk::~Chunk() {
  // If the memory for this chunk is external we leave it alone
  // and let the embedder deallocate it.
  if (is_external()) return;
  GCMetadata::mark_pages_for_chunk(this, UNKNOWN_SPACE_PAGE);
  OS::free_pages(reinterpret_cast<void*>(start_), size());
}

Space::~Space() {
  WeakPointer::force_callbacks(&weak_pointers_);
  free_all_chunks();
}

void Space::free_all_chunks() {
  for (auto it = chunk_list_.begin(); it != chunk_list_.end();) {
    Chunk* current = *it;
    it = chunk_list_.erase(it);
    ObjectMemory::free_chunk(current);
  }
  top_ = limit_ = 0;
}

uword Space::size() {
  uword result = 0;
  for (auto chunk : chunk_list_) result += chunk->size();
  ASSERT(used() <= result);
  return result;
}

word Space::offset_of(HeapObject* object) {
  uword address = object->address();
  uword start = chunk_list_.first()->start();

  // Make sure the space consists of exactly one chunk!
  ASSERT(chunk_list_.first() == chunk_list_.last());
  ASSERT(chunk_list_.first()->includes(address));
  ASSERT(start <= address);

  return address - start;
}

HeapObject *Space::object_at_offset(word offset) {
  uword start = chunk_list_.first()->start();
  uword address = offset + start;

  // Make sure the space consists of exactly one chunk!
  ASSERT(chunk_list_.first() == chunk_list_.last());

  ASSERT(chunk_list_.first()->includes(address));
  ASSERT(start <= address);

  return HeapObject::from_address(address);
}

void Space::adjust_allocation_budget(uword used_outside_space) {
  uword used = used() + used_outside_space;
  // Allow heap size to double (but we may hit maximum heap size limits before
  // that).
  allocation_budget_ = used + PAGE_SIZE;
}

void Space::increase_allocation_budget(uword size) { allocation_budget_ += size; }

void Space::decrease_allocation_budget(uword size) { allocation_budget_ -= size; }

void Space::set_allocation_budget(word new_budget) {
  allocation_budget_ = Utils::max(
      static_cast<word>(default_chunk_size(new_budget)), new_budget);
}

void Space::iterate_overflowed_objects(PointerVisitor* visitor, MarkingStack* stack) {
  static_assert(
      PAGE_SIZE % (1 << GCMetadata::CARD_SIZE_IN_BITS_LOG_2) == 0,
      "MarkStackOverflowBytesMustCoverAFractionOfAPage");

  for (auto chunk : chunk_list_) {
    uint8* bits = GCMetadata::overflow_bits_for(chunk->start());
    uint8* bits_limit = GCMetadata::overflow_bits_for(chunk->end());
    uword card = chunk->start();
    for (; bits < bits_limit; bits++) {
      for (int i = 0; i < 8; i++, card += GCMetadata::CARD_SIZE) {
        // Skip cards 8 at a time if they are clear.
        if (*bits == 0) {
          card += GCMetadata::CARD_SIZE * (8 - i);
          break;
        }
        if ((*bits & (1 << i)) != 0) {
          // Clear the bit immediately, since the mark stack could overflow and
          // a different object in this card could fail to push, setting the
          // bit again.
          *bits &= ~(1 << i);
          uint8 start = *GCMetadata::starts_for(card);
          ASSERT(start != GCMetadata::NO_OBJECT_START);
          uword object_address = (card | start);
          for (HeapObject* object;
               object_address < card + GCMetadata::CARD_SIZE &&
               !has_sentinel_at(object_address);
               object_address += object->size()) {
            object = HeapObject::from_address(object_address);
            if (GCMetadata::is_grey(object)) {
              GCMetadata::mark_all(object, object->size());
              object->iterate_pointers(visitor);
            }
          }
        }
      }
      stack->empty(visitor);
    }
  }
}

void Space::iterate_objects(HeapObjectVisitor* visitor) {
  if (is_empty()) return;
  flush();
  for (auto chunk : chunk_list_) {
    visitor->chunk_start(chunk);
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::from_address(current);
      word size = visitor->visit(object);
      ASSERT(size > 0);
      current += size;
    }
    visitor->chunk_end(chunk, current);
  }
}

void SemiSpace::complete_scavenge(PointerVisitor* visitor) {
  flush();
  for (auto chunk : chunk_list_) {
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::from_address(current);
      object->iterate_pointers(visitor);
      current += object->size();
      flush();
    }
  }
}

void Space::clear_mark_bits() {
  flush();
  for (auto chunk : chunk_list_) GCMetadata::clear_mark_bits_for(chunk);
}

bool Space::includes(uword address) {
  for (auto chunk : chunk_list_)
    if (chunk->includes(address)) return true;
  return false;
}

#ifdef DEBUG
void Space::find(uword w, const char* name) {
  for (auto chunk : chunk_list_) chunk->find(w, name);
}
#endif

void Space::complete_transformations(PointerVisitor* visitor) {
  flush();
  for (auto chunk : chunk_list_) {
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::from_address(current);
      if (object->has_forwarding_address()) {
        current += Instance::kSize;
      } else {
        object->iterate_pointers(visitor);
        current += object->size();
      }
      flush();
    }
  }
}

Atomic<uword> ObjectMemory::allocated_;

void ObjectMemory::set_up() {
  allocated_ = 0;
  GCMetadata::set_up();
}

void ObjectMemory::tear_down() {
  GCMetadata::tear_down();
}

#ifdef DEBUG
void Chunk::scramble() {
  void* p = reinterpret_cast<void*>(start_);
  memset(p, 0xab, size());
}

void Chunk::find(uword word, const char* name) {
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

Chunk* ObjectMemory::allocate_chunk(Space* owner, uword size) {
  ASSERT(owner != NULL);

  size = Utils::round_up(size, PAGE_SIZE);
  void* memory =
      OS::allocate_pages(size, GCMetadata::heap_allocation_arena());
  uword lowest = GCMetadata::lowest_old_space_address();
  USE(lowest);
  if (memory == NULL) return NULL;
  ASSERT(reinterpret_cast<uword>(memory) >= lowest);
  ASSERT(reinterpret_cast<uword>(memory) - lowest + size <=
         GCMetadata::heap_extent());

  uword base = reinterpret_cast<uword>(memory);
  Chunk* chunk = new Chunk(owner, base, size);

  ASSERT(base == Utils::round_up(base, PAGE_SIZE));
  ASSERT(size == Utils::round_up(size, PAGE_SIZE));

#ifdef DEBUG
  chunk->scramble();
#endif
  GCMetadata::mark_pages_for_chunk(chunk, owner->page_type());
  allocated_ += size;
  return chunk;
}

Chunk* ObjectMemory::create_fixed_chunk(Space* owner, void* memory, uword size) {
  ASSERT(owner != NULL);
  ASSERT(size == Utils::round_up(size, PAGE_SIZE));

  uword base = reinterpret_cast<uword>(memory);
  ASSERT(base % PAGE_SIZE == 0);

  Chunk* chunk = new Chunk(owner, base, size, true);
  GCMetadata::mark_pages_for_chunk(chunk, owner->page_type());
  return chunk;
}

void ObjectMemory::free_chunk(Chunk* chunk) {
#ifdef DEBUG
  // Do not touch external memory. It might be read-only.
  if (!chunk->is_external()) chunk->scramble();
#endif
  allocated_ -= chunk->size();
  delete chunk;
}

// Put free-list entries on the objects that are now dead.
void OldSpace::rebuild_after_transformations() {
  for (auto chunk : chunk_list_) {
    uword free_start = 0;
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::from_address(current);
      if (object->has_forwarding_address()) {
        if (free_start == 0) free_start = current;
        current += Instance::kSize;
        while (HeapObject::from_address(current)->is_filler()) {
          current += WORD_SIZE;
        }
      } else {
        if (free_start != 0) {
          free_list_->add_chunk(free_start, current - free_start);
          free_start = 0;
        }
        current += object->size();
      }
    }
  }
}

// Put one-word-fillers on the dead objects so it is still iterable.
void SemiSpace::rebuild_after_transformations() {
  for (auto chunk : chunk_list_) {
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::from_address(current);
      if (object->has_forwarding_address()) {
        for (int i = 0; i < Instance::kSize; i += WORD_SIZE) {
          *reinterpret_cast<Object**>(current + i) =
              StaticClassStructures::one_word_filler_class();
        }
        current += Instance::kSize;
      } else {
        current += object->size();
      }
    }
  }
}

#ifdef DEBUG
NoAllocationScope::NoAllocationScope(Heap* heap) : heap_(heap) {
  heap->increment_no_allocation();
}

NoAllocationScope::~NoAllocationScope() { heap_->decrement_no_allocation(); }
#endif

}  // namespace dartino
