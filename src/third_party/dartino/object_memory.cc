// Copyright (c) 2022, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "object_memory.h"

#include <stdlib.h>
#include <stdio.h>

#include "../../top.h"

#include "../../objects.h"
#include "../../os.h"
#include "../../utils.h"
#include "gc_metadata.h"
#include "mark_sweep.h"

namespace toit {

Chunk::Chunk(Space* owner, uword start, uword size)
      : owner_(owner),
        start_(start),
        end_(start + size),
        scavenge_pointer_(start_) {
  if (!GcMetadata::in_metadata_range(start)) {
    FATAL("Not in metadata range: %p\n", (void*)start);
  }
}

Chunk::~Chunk() {
  GcMetadata::mark_pages_for_chunk(this, UNKNOWN_SPACE_PAGE);
  OS::free_pages(reinterpret_cast<void*>(start_), size());
}

Space::~Space() {
  // ObjectHeap destructor already called all finalizers.
  free_all_chunks();
}

void Space::free_all_chunks() {
  while (auto it = chunk_list_.first()) {
    chunk_list_.unlink(it);
    ObjectMemory::free_chunk(it);
  }

  top_ = limit_ = 0;
}

uword Space::size() const {
  uword result = 0;
  for (auto chunk : chunk_list_) result += chunk->size();
  ASSERT(used() <= result);
  return result;
}

word Space::offset_of(HeapObject* object) {
  uword address = object->_raw();
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

void Space::iterate_overflowed_objects(RootCallback* visitor, MarkingStack* stack) {
  static_assert(
      TOIT_PAGE_SIZE % (1 << GcMetadata::CARD_SIZE_IN_BITS_LOG_2) == 0,
      "MarkStackOverflowBytesMustCoverAFractionOfAPage");

  for (auto chunk : chunk_list_) {
    uint8* bits = GcMetadata::overflow_bits_for(chunk->start());
    uint8* bits_limit = GcMetadata::overflow_bits_for(chunk->end());
    uword card = chunk->start();
    for (; bits < bits_limit; bits++) {
      for (int i = 0; i < 8; i++, card += GcMetadata::CARD_SIZE) {
        // Skip cards 8 at a time if they are clear.
        if (*bits == 0) {
          card += GcMetadata::CARD_SIZE * (8 - i);
          break;
        }
        if ((*bits & (1 << i)) != 0) {
          // Clear the bit immediately, since the mark stack could overflow and
          // a different object in this card could fail to push, setting the
          // bit again.
          *bits &= ~(1 << i);
          uint8 start = *GcMetadata::starts_for(card);
          ASSERT(start != GcMetadata::NO_OBJECT_START);
          uword object_address = (card | start);
          for (HeapObject* object;
               object_address < card + GcMetadata::CARD_SIZE &&
               !has_sentinel_at(object_address);
               object_address += object->size(program_)) {
            object = HeapObject::from_address(object_address);
            if (GcMetadata::is_grey(object)) {
              GcMetadata::mark_all(object, object->size(program_));
              object->roots_do(program_, visitor);
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

void Space::clear_mark_bits() {
  flush();
  for (auto chunk : chunk_list_) GcMetadata::clear_mark_bits_for_chunk(chunk);
}

bool Space::includes(uword address) {
  for (auto chunk : chunk_list_)
    if (chunk->includes(address)) return true;
  return false;
}

class InSpaceVisitor : public RootCallback {
 public:
  explicit InSpaceVisitor(Space* space) : space(space) {}
  void do_roots(Object** p, int length) {
    for (int i = 0; i < length; i++) {
      Object* object = p[i];
      if (is_smi(object)) continue;
      if (space->includes(reinterpret_cast<uword>(object))) {
        in_space = true;
        break;
      }
    }
  }
  bool in_space = false;

 private:
  Space* space;
};

bool HeapObject::contains_pointers_to(Program* program, Space* space) {
  InSpaceVisitor visitor(space);
  roots_do(program, &visitor);
  return visitor.in_space;
}

#ifdef TOIT_DEBUG
void Space::find(uword w, const char* name) {
  for (auto chunk : chunk_list_) chunk->find(w, name);
}
#endif

std::atomic<uword> ObjectMemory::allocated_;
Chunk* ObjectMemory::spare_chunk_ = null;
Mutex* ObjectMemory::spare_chunk_mutex_ = null;

void ObjectMemory::tear_down() {
  GcMetadata::tear_down();
  if (!spare_chunk_mutex_) FATAL("ObjectMemory::tear_down without set_up");
  OS::dispose(spare_chunk_mutex_);
  spare_chunk_mutex_ = null;
  free_chunk(spare_chunk_);
  spare_chunk_ = null;
}

#ifdef TOIT_DEBUG
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
  static const int UNUSABLE_SIZE = 50;
  void* unusable_pages[UNUSABLE_SIZE];
  size = Utils::round_up(size, TOIT_PAGE_SIZE);
  uword lowest = GcMetadata::lowest_old_space_address();
  for (int i = 0; i < UNUSABLE_SIZE; i++) {
    void* memory = OS::allocate_pages(size);
    if (memory == null ||
        (GcMetadata::in_metadata_range(memory) &&
         GcMetadata::in_metadata_range(reinterpret_cast<uword>(memory) + size - 1))) {
      for (int j = 0; j < i; j++) OS::free_pages(unusable_pages[j], size);
      return allocate_chunk_helper(owner, size, memory);
    }
    unusable_pages[i] = memory;
  }
  printf("New allocation %p-%p\n", unusable_pages[0], unvoid_cast<char*>(unusable_pages[0]) + size);
  printf("Metadata range %p-%p\n", reinterpret_cast<void*>(lowest), reinterpret_cast<uint8*>(lowest) + GcMetadata::heap_extent());
  FATAL("Toit heap outside expected range");
}


Chunk* ObjectMemory::allocate_chunk_helper(Space* owner, uword size, void* memory) {
  if (memory == null) return null;

  uword base = reinterpret_cast<uword>(memory);
  Chunk* chunk = _new Chunk(owner, base, size);
  if (!chunk) {
    OS::free_pages(memory, size);
    return null;
  }

  ASSERT(base == Utils::round_up(base, TOIT_PAGE_SIZE));
  ASSERT(size == Utils::round_up(size, TOIT_PAGE_SIZE));

#ifdef TOIT_DEBUG
  chunk->scramble();
#endif
  if (owner) {
    GcMetadata::mark_pages_for_chunk(chunk, owner->page_type());
    chunk->initialize_metadata();
  }
  allocated_ += size;
  return chunk;
}

void Chunk::set_owner(Space* value) {
  owner_ = value;
  GcMetadata::mark_pages_for_chunk(this, value->page_type());
  initialize_metadata();
}

void Chunk::initialize_metadata() const {
  GcMetadata::clear_mark_bits_for_chunk(this);
  GcMetadata::initialize_overflow_bits_for_chunk(this);
  GcMetadata::initialize_starts_for_chunk(this);
  GcMetadata::initialize_remembered_set_for_chunk(this);
}

void ObjectMemory::free_chunk(Chunk* chunk) {
#ifdef TOIT_DEBUG
  chunk->scramble();
#endif
  allocated_ -= chunk->size();
  delete chunk;
}

void ObjectMemory::set_up() {
  allocated_ = 0;
  GcMetadata::set_up();
  spare_chunk_ = allocate_chunk(null, TOIT_PAGE_SIZE);
  if (!spare_chunk_) FATAL("Can't allocate initial spare chunk");
  if (spare_chunk_mutex_) FATAL("Can't call ObjectMemory::set_up twice");
  spare_chunk_mutex_ = OS::allocate_mutex(6, "Spare memory chunk");
}

}  // namespace toit
