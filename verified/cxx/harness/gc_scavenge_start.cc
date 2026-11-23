// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
static void initialize_table(void*, int, size_t);
#define memset initialize_table
#include "third_party/dartino/gc_metadata.h"
#undef memset
#include "third_party/dartino/object_memory.cc"
#include "third_party/dartino/object_memory_copying.cc"
#undef protected
#undef private

using namespace toit;
extern TwoSpaceHeap heap;
extern Program image;
GcMetadata GcMetadata::singleton_;
constexpr int cards = TOIT_PAGE_SIZE / GcMetadata::CARD_SIZE;
alignas(TOIT_PAGE_SIZE) static Object* page[TOIT_PAGE_SIZE / WORD_SIZE];
static uint8 kinds[2], marks[2 * TOIT_PAGE_SIZE / (8 * WORD_SIZE)];
static uint8 starts[2 * cards], remembered[2 * cards], overflow[2 * cards / 8];
static unsigned slot, initialized;
static bool constructing;
static uint8* retiring;
static unsigned retire_fills;

static void initialize_table(void* p, int value, size_t bytes) {
  if (retiring) {
    CXXV_ASSERT(p == retiring && value == UNKNOWN_SPACE_PAGE && bytes == 1,
                "detach changes only the selected page classification");
    retire_fills++;
    return;
  }
  if (!constructing) return;
  if (p == kinds + slot) {
    CXXV_ASSERT(value == NEW_SPACE_PAGE && bytes == 1, "classify just the destination page");
    initialized |= 1;
  } else if (p == marks + slot * sizeof(marks) / 2) {
    CXXV_ASSERT(value == 0 && bytes == sizeof(marks) / 2, "clear the destination mark bits");
    initialized |= 2;
  } else if (p == starts + slot * cards) {
    CXXV_ASSERT(value == GcMetadata::NO_OBJECT_START && bytes == cards, "initialize destination object starts");
    initialized |= 4;
  } else if (p == remembered + slot * cards) {
    CXXV_ASSERT(value == GcMetadata::NO_NEW_SPACE_POINTERS && bytes == cards, "clear destination remembered cards");
    initialized |= 8;
  } else {
    CXXV_ASSERT(p == overflow + slot * cards / 8 && value == 0 && bytes == cards / 8, "clear destination overflow bits");
    initialized |= 16;
  }
}
void OS::free_pages(void*, uword) {}
void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "supplied descriptors are within the metadata mapping");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  slot = nondet_bool() ? 1 : 0;
  uword dst = reinterpret_cast<uword>(page);
  CXXV_ASSUME(dst % TOIT_PAGE_SIZE == 0 && dst >= TOIT_PAGE_SIZE && dst <= INTPTR_MAX - 2 * TOIT_PAGE_SIZE);
  uword base = dst - slot * TOIT_PAGE_SIZE;
  uword src = base + (1 - slot) * TOIT_PAGE_SIZE;
  auto& m = GcMetadata::singleton_;
  m.lowest_address_ = base;
  m.heap_extent_ = 2 * TOIT_PAGE_SIZE;
  m.page_type_bytes_ = kinds;
  m.mark_bits_bias_ = reinterpret_cast<uword>(marks) - base / (8 * WORD_SIZE);
  m.starts_bias_ = reinterpret_cast<uword>(starts) - base / GcMetadata::CARD_SIZE;
  m.remembered_set_bias_ = reinterpret_cast<uword>(remembered) - base / GcMetadata::CARD_SIZE;
  m.overflow_bits_bias_ = reinterpret_cast<uword>(overflow) - base / (8 * GcMetadata::CARD_SIZE);
  auto from = new (heap.new_space()) SemiSpace(&image, nullptr);
  Chunk source(from, src, TOIT_PAGE_SIZE), spare(nullptr, dst, TOIT_PAGE_SIZE);
  auto source_anchor = &from->chunk_list_.anchor_;
  CXXV_ASSERT(source_anchor->next_ == source_anchor && source_anchor->prev_ == source_anchor &&
              from->remove_chunk() == nullptr, "an empty space has a circular anchor and yields no chunk");
  CXXV_ASSERT(source.next_ == &source && source.prev_ == &source && spare.next_ == &spare && spare.prev_ == &spare,
              "new descriptors have detached links");
  from->chunk_list_.append(&source);
  heap.water_mark_ = nondet_ulong();
  CXXV_ASSUME(src <= heap.water_mark_ && heap.water_mark_ <= src + TOIT_PAGE_SIZE);
  Object** first = page;
  Object** probe = page + nondet_uint() % ARRAY_SIZE(page);
  *first = Smi::from(1);
  *probe = Smi::from(2);
  constructing = true;
  ScavengeVisitor visitor(&image, &heap, &spare);
  constructing = false;
  SemiSpace* to = visitor.to_space();
  CXXV_ASSERT(initialized == 31, "initialize all five destination tables");
  CXXV_ASSERT(to->chunk() == &spare && to->chunk_list_.last() == &spare && spare.owner() == to &&
              to->top_ == dst && to->limit_ == dst + TOIT_PAGE_SIZE && to->page_type() == NEW_SPACE_PAGE,
              "install the borrowed page as an empty allocation window");
  CXXV_ASSERT(*first == 0 && (probe == first || *probe == Smi::from(2)),
              "write the destination sentinel and preserve every other payload word");
  CXXV_ASSERT(from->chunk() == &source && source.owner() == from && visitor.from_start_ == src &&
              visitor.to_start_ == dst && visitor.from_size_ == TOIT_PAGE_SIZE && visitor.to_size_ == TOIT_PAGE_SIZE,
              "preserve source membership and install disjoint classification ranges");
  CXXV_ASSERT(visitor.program_ == &image && visitor.old_ == heap.old_space() && visitor.water_mark_ == heap.water_mark_ &&
              visitor.record_ == &visitor.dummy_record_ && !visitor.trigger_old_space_gc(),
              "initialize the promotion boundary, fallback record and collection state");
  auto to_anchor = &to->chunk_list_.anchor_;
  CXXV_ASSERT(spare.next_ == to_anchor && spare.prev_ == to_anchor &&
              source.next_ == source_anchor && source.prev_ == source_anchor,
              "each descriptor links back to its own space in both directions");
  Space* first_space = nondet_bool() ? to : from;
  Space* second_space = first_space == to ? from : to;
  Chunk* removed = first_space == to ? &spare : &source;
  Chunk* remaining = first_space == to ? &source : &spare;
  retiring = kinds + (first_space == to ? slot : 1 - slot);
  Chunk* detached = first_space->remove_chunk();
  CXXV_ASSERT(detached == removed && retire_fills == 1, "remove and reclassify the selected descriptor once");
  auto empty = &first_space->chunk_list_.anchor_;
  auto occupied = &second_space->chunk_list_.anchor_;
  CXXV_ASSERT(removed->owner() == nullptr && removed->next_ == removed && removed->prev_ == removed &&
              empty->next_ == empty && empty->prev_ == empty, "restore both detached rings");
  CXXV_ASSERT(occupied->next_ == remaining && occupied->prev_ == remaining && remaining->next_ == occupied &&
              remaining->prev_ == occupied && remaining->owner() == second_space, "preserve the other space's ring");
  detached = first_space->remove_chunk();
  CXXV_ASSERT(detached == nullptr && retire_fills == 1, "repeated removal leaves metadata untouched");
  retiring = kinds + (second_space == to ? slot : 1 - slot);
  detached = second_space->remove_chunk();
  CXXV_ASSERT(detached == remaining && retire_fills == 2, "remove and reclassify the remaining descriptor once");
  retiring = nullptr;
}
