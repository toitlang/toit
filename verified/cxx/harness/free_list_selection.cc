// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "objects.cc"
#include "third_party/dartino/object_memory.h"
#undef protected
#undef private

using namespace toit;

// Independent of the leading-zero count used by the native bucket index.
static int bucket_for(uword size) {
  int bucket = 0;
  while (bucket + 1 < FreeList::NUMBER_OF_BUCKETS && size >= (uword{2} << bucket)) ++bucket;
  return bucket;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  FreeList list;
  const int count = 3;
  FreeListRegion* nodes[count];
  int buckets[count];
  int selected = -1;
  int best_bucket = -1;
  uword minimum = nondet_ulong();
  CXXV_ASSUME(minimum != 0);
  for (int i = 0; i < count; ++i) {
    word size = nondet_word();
    CXXV_ASSUME(size >= WORD_SIZE && size % WORD_SIZE == 0);
    void* raw = malloc(size);
    CXXV_ASSUME(raw != nullptr && reinterpret_cast<uword>(raw) % WORD_SIZE == 0);
    list.add_region(reinterpret_cast<uword>(raw), size);
    auto* region = static_cast<FreeListRegion*>(HeapObject::from_address(reinterpret_cast<uword>(raw)));
    if (size < FreeListRegion::MINIMUM_SIZE) {
      nodes[i] = nullptr;
      buckets[i] = -1;
      for (word offset = 0; offset < size; offset += WORD_SIZE) {
        auto* filler = HeapObject::from_address(reinterpret_cast<uword>(raw) + offset);
        CXXV_ASSERT(filler->has_class_tag(SINGLE_FREE_WORD_TAG), "each undersized word is a walkable filler");
      }
    } else {
      nodes[i] = region;
      buckets[i] = bucket_for(size);
      CXXV_ASSERT(region->has_class_tag(FREE_LIST_REGION_TAG) && region->size() == static_cast<uword>(size),
                  "record the original free region extent");
      if (static_cast<uword>(size) >= minimum && buckets[i] >= best_bucket) {
        best_bucket = buckets[i];
        selected = i;
      }
    }
  }
  FreeListRegion* found = list.get_region(minimum);
  CXXV_ASSERT(found == (selected < 0 ? nullptr : nodes[selected]), "pick the newest fit in the largest fitting bucket");
  if (found != nullptr) CXXV_ASSERT(found->next_region() == nullptr && found->size() >= minimum, "detach a sufficient region");
  FreeListRegion* expected[FreeList::NUMBER_OF_BUCKETS] = {};
  for (int i = 0; i < count; ++i) {
    if (i != selected && nodes[i] != nullptr) {
      int b = buckets[i];
      CXXV_ASSERT(nodes[i]->next_region() == expected[b], "preserve every remaining link in insertion order");
      expected[b] = nodes[i];
    }
  }
  for (int b = 0; b < FreeList::NUMBER_OF_BUCKETS; ++b) {
    CXXV_ASSERT(list.buckets_[b] == expected[b], "retain exactly the surviving regions in every bucket");
  }
}
