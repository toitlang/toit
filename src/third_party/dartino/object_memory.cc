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
  for (auto chunk : chunk_list_) {
    result += chunk->size();
  }
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

HeapObject* Space::object_at_offset(word offset) {
  uword start = chunk_list_.first()->start();
  uword address = offset + start;

  // Make sure the space consists of exactly one chunk!
  ASSERT(chunk_list_.first() == chunk_list_.last());

  ASSERT(chunk_list_.first()->includes(address));
  ASSERT(start <= address);

  return HeapObject::from_address(address);
}

// Callbacks can flag additional cards, including the card being scanned.
template<typename ScanCard>
static inline void scan_overflow_byte(uint8* bits, uword first_card, ScanCard scan) {
  for (int i = 0; i < 8 && *bits != 0; ++i) {
    unsigned mask = 1U << i;
    if ((*bits & mask) == 0) continue;
    *bits &= ~mask;
    scan(first_card + i * GcMetadata::CARD_SIZE);
  }
}

static void scan_overflow_card(Program* program, RootCallback* visitor, uword address, uword limit) {
  while (address < limit) {
    if (has_sentinel_at(address)) {
      break;
    }
    HeapObject* object = HeapObject::from_address(address);
    if (GcMetadata::is_grey(object)) {
      object->roots_do(program, visitor);  // Stack visitation may shrink the object.
      GcMetadata::mark_all(object, object->size(program));
    }
    address += object->size(program);
  }
}

template<typename ScanRange>
static inline void scan_overflow_group(uint8* bits, uword card, ScanRange scan) {
  scan_overflow_byte(bits, card, [&](uword current_card) {
    uint8 start = *GcMetadata::starts_for(current_card);
    ASSERT(start != GcMetadata::NO_OBJECT_START);
    scan(current_card | start, current_card + GcMetadata::CARD_SIZE);
  });
}

static void scan_overflow_group(Program* program, RootCallback* visitor, uint8* bits, uword card) {
  scan_overflow_group(bits, card, [&](uword start, uword limit) {
    scan_overflow_card(program, visitor, start, limit);
  });
}

static_assert(TOIT_PAGE_SIZE % (8 * GcMetadata::CARD_SIZE) == 0, "overflow groups must divide a page");

static void scan_overflow_chunk(Program* program, RootCallback* visitor, MarkingStack* stack, uword start, uword end) {
  uint8* bits = GcMetadata::overflow_bits_for(start);
  for (uword card = start; card < end; card += 8 * GcMetadata::CARD_SIZE) {
    scan_overflow_group(program, visitor, bits, card);
    ++bits;
    stack->empty(visitor);
  }
}

void Space::iterate_overflowed_objects(RootCallback* visitor, MarkingStack* stack) const {
  for (auto chunk : chunk_list_) {
    scan_overflow_chunk(program_, visitor, stack, chunk->start(), chunk->end());
  }
}

void Space::iterate_chunks(void* context, Process* process, process_chunk_callback_t* callback) {
  if (is_empty()) return;
  for (auto chunk : chunk_list_) {
    callback(context, process, chunk->start(), chunk->size());
  }
}

void Space::iterate_objects(HeapObjectVisitor* visitor, LivenessOracle* filter) {
  if (is_empty()) return;
  flush();
  for (auto chunk : chunk_list_) {
    visitor->chunk_start(chunk);
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::from_address(current);
      if (!filter || filter->is_alive(object)) {
        word size = visitor->visit(object);
        ASSERT(size > 0);
        current += size;
      } else {
        word size = object->size(program_);
#ifdef DEBUG
        // Zapping words after the header should be harmless in new-space.
        // In old-space this would interfere with the remembered set scanning,
        // but there we don't use this call with a non-null filter.
        uword address = object->_raw();
        memset(reinterpret_cast<void*>(address + WORD_SIZE), 0x55, size - WORD_SIZE);
#endif
        current += size;
      }
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
  void do_roots(Object** p, word length) {
    for (word i = 0; i < length; i++) {
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

Chunk* ObjectMemory::take_spare_chunk(Locker& locker) {
  ASSERT(locker.mutex() == spare_chunk_mutex_ && spare_chunk_ != nullptr);
  Chunk* chunk = spare_chunk_;
  spare_chunk_ = nullptr;
#ifdef TOIT_FREERTOS
  // Prefer a lower page for new space when the allocator can supply one.
  Chunk* candidate = allocate_chunk(null, TOIT_PAGE_SIZE);
  if (candidate) {
    if (candidate->start() < chunk->start()) {
      free_chunk(chunk);
      return candidate;
    }
    free_chunk(candidate);
  }
#endif
  return chunk;
}

void ObjectMemory::tear_down() {
  if (!spare_chunk_mutex_) FATAL("ObjectMemory::tear_down without set_up");
  OS::dispose(spare_chunk_mutex_);
  spare_chunk_mutex_ = null;
  free_chunk(spare_chunk_);
  spare_chunk_ = null;
  // Chunk destruction still updates the page metadata.
  GcMetadata::tear_down();
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
  if (size == 0 || size > UINTPTR_MAX - (TOIT_PAGE_SIZE - 1)) return null;
  size = Utils::round_up(size, TOIT_PAGE_SIZE);
#ifdef TOIT_FREERTOS
  static const int UNUSABLE_SIZE = 50;
  void* unusable_pages[UNUSABLE_SIZE];
  void* memory = null;
  int rejected = 0;
  for (; rejected < UNUSABLE_SIZE; rejected++) {
    void* candidate = OS::allocate_pages(size);
    if (!candidate) break;
    if (GcMetadata::contains_chunk(candidate, size)) {
      memory = candidate;
      break;
    }
    unusable_pages[rejected] = candidate;
  }
  for (int i = 0; i < rejected; i++) OS::free_pages(unusable_pages[i], size);
#else
  void* memory = OS::allocate_pages(size);
#endif
  if (!memory) return null;
  return allocate_chunk_helper(owner, size, memory);
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
  GcMetadata::map_metadata_for_chunk(chunk);
  if (owner) {
    GcMetadata::mark_pages_for_chunk(chunk, owner->page_type());
    chunk->initialize_metadata();
  }
  allocated_ += size;
  return chunk;
}

void Chunk::set_owner(Space* value) {
  owner_ = value;
  GcMetadata::mark_pages_for_chunk(this, value ? value->page_type() : UNKNOWN_SPACE_PAGE);
  if (value) initialize_metadata();
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
  if (spare_chunk_mutex_) FATAL("Can't call ObjectMemory::set_up twice");
  allocated_ = 0;
  GcMetadata::set_up();
  Chunk* chunk = allocate_chunk(null, TOIT_PAGE_SIZE);
  if (!chunk) {
    GcMetadata::tear_down();
    FATAL("Can't allocate initial spare chunk");
  }
  Mutex* mutex = OS::allocate_mutex(7, "Spare memory chunk");
  if (!mutex) {
    free_chunk(chunk);
    GcMetadata::tear_down();
    FATAL("Can't allocate spare memory mutex");
  }
  spare_chunk_ = chunk;
  spare_chunk_mutex_ = mutex;
}

}  // namespace toit
