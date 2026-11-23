// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
static void fill_metadata(void*, int, size_t);
#define memset fill_metadata
#include "third_party/dartino/gc_metadata.h"
#undef memset
#include "third_party/dartino/object_memory.cc"
#include "third_party/dartino/object_memory_copying.cc"
#include "third_party/dartino/two_space_heap.cc"
#undef protected
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;
extern TwoSpaceHeap heap;
extern ObjectHeap process_heap;
extern Mutex spare_mutex;
extern Program program;
extern Chunk old_space_chunk;
static uint8 kinds[4];
static uint8* retiring;
static unsigned fills;

static void fill_metadata(void* address, int value, size_t bytes) {
  if (retiring) {
    CXXV_ASSERT(address == retiring && value == UNKNOWN_SPACE_PAGE && bytes == 1,
                "the handoff writes only the outgoing page-type byte");
    ++fills;
  }
  memset(address, value, bytes);
}
static bool locked;
static Chunk* outgoing;
void OS::free_pages(void*, uword) {}
void Locker::enter() {
  CXXV_ASSERT(!locked && mutex() == &spare_mutex, "enter the spare mutex once");
  locked = true;
}
void Locker::leave() {
  CXXV_ASSERT(locked && ObjectMemory::spare_chunk_ == outgoing, "publish the outgoing page before unlocking");
  locked = false;
}
void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "valid page handoff avoids fatal errors");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword base = nondet_ulong();
  CXXV_ASSUME(base != 0 && base % TOIT_PAGE_SIZE == 0 &&
              base <= UINTPTR_MAX - sizeof(kinds) * TOIT_PAGE_SIZE);
  auto& meta = GcMetadata::singleton_;
  meta.lowest_address_ = base;
  meta.heap_extent_ = sizeof(kinds) * TOIT_PAGE_SIZE;
  meta.page_type_bytes_ = kinds;
  meta.large_heap_heuristics_ = nondet_int();
  // Only the page-type table is supplied. Reinitializing survivor metadata
  // would access storage outside the fixture and fail pointer checking.
  unsigned slot = nondet_uint() % sizeof(kinds);
  unsigned destination = nondet_uint() % sizeof(kinds);
  CXXV_ASSUME(destination != slot);
  unsigned probe = nondet_uint() % sizeof(kinds);
  uint8 original = static_cast<uint8>(nondet_uint());
  kinds[probe] = original;
  uword old_base = base + slot * TOIT_PAGE_SIZE;
  uword new_base = base + destination * TOIT_PAGE_SIZE;
  auto& from = *new (heap.new_space()) SemiSpace(&program, nullptr);
  SemiSpace to(&program, nullptr);
  Chunk old_chunk(&from, old_base, TOIT_PAGE_SIZE);
  Chunk survivor_chunk(nullptr, new_base, TOIT_PAGE_SIZE);
  outgoing = &old_chunk;
  Chunk* survivor = &survivor_chunk;
  kinds[slot] = NEW_SPACE_PAGE;
  kinds[destination] = UNKNOWN_SPACE_PAGE;
  heap.process_heap_ = &process_heap;
  auto old_anchor = &heap.old_space()->chunk_list_.anchor_;
  old_anchor->next_ = old_anchor->prev_ = old_anchor;
  bool old_empty = nondet_bool();
  if (!old_empty) heap.old_space()->chunk_list_.append(&old_space_chunk);
  heap.large_allocation_failed_ = nondet_bool();
  process_heap.max_heap_size_ = nondet_ulong();
  process_heap.limit_ = nondet_ulong();
  bool capped_to_page = process_heap.max_heap_size_ != 0 && static_cast<uword>(process_heap.limit_) <= TOIT_PAGE_SIZE;
  bool postpone_promotion = old_empty && !heap.large_allocation_failed_ && meta.large_heap_heuristics_ < 40;
  from.chunk_list_.append(outgoing);
  from.top_ = old_base;
  from.limit_ = old_base + TOIT_PAGE_SIZE;
  ObjectMemory::spare_chunk_mutex_ = &spare_mutex;
  ObjectMemory::spare_chunk_ = survivor;
  {
    Locker locker(&spare_mutex);
    Chunk* borrowed = ObjectMemory::take_spare_chunk(locker);
    CXXV_ASSERT(locked && borrowed == survivor && !ObjectMemory::spare_chunk_, "borrow once under the lock");
    // Start the handoff with any valid amount copied into the borrowed page.
    borrowed->owner_ = &to;
    kinds[destination] = NEW_SPACE_PAGE;
    to.chunk_list_.append(borrowed);
    uword used = nondet_ulong();
    CXXV_ASSUME(used < TOIT_PAGE_SIZE && used % WORD_SIZE == 0);
    to.top_ = new_base + used;
    to.limit_ = new_base + TOIT_PAGE_SIZE;
    retiring = &kinds[slot];
    ObjectMemory::set_spare_chunk(locker, heap.swap_semi_spaces(from, to));
    CXXV_ASSERT(fills == 1, "classify the outgoing page exactly once");
    retiring = nullptr;
    CXXV_ASSERT(to.is_empty() && to.top_ == 0 && to.limit_ == 0 && from.chunk_list_.first() == survivor && from.chunk_list_.last() == survivor &&
                survivor->owner() == &from, "the persistent semispace owns the sole survivor chunk");
    auto anchor = &from.chunk_list_.anchor_;
    CXXV_ASSERT(survivor->prev_ == anchor && survivor->next_ == anchor, "both survivor links reference the persistent space");
    CXXV_ASSERT(outgoing->owner() == nullptr && outgoing->prev_ == outgoing && outgoing->next_ == outgoing &&
                ObjectMemory::spare_chunk_ == outgoing, "return only the detached source page");
    CXXV_ASSERT(kinds[slot] == UNKNOWN_SPACE_PAGE && kinds[destination] == NEW_SPACE_PAGE &&
                (probe == slot || probe == destination || kinds[probe] == original),
                "retire only the source page classification");
    CXXV_ASSERT(from.top_ == new_base + used && from.limit_ == new_base + TOIT_PAGE_SIZE,
                "preserve survivor allocation bounds");
    bool reset = (postpone_promotion && used < TOIT_PAGE_SIZE / 2) || capped_to_page;
    CXXV_ASSERT(heap.water_mark_ == new_base + (reset ? 0 : used), "retain the survivor promotion threshold");
  }
  CXXV_ASSERT(!locked, "release the shared spare lock");
  from.chunk_list_.unlink(survivor);  // End the fixture before retiring its descriptors.
}
