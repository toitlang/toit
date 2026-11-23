// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/object_memory.cc"
#include "third_party/dartino/gc_metadata.h"
#undef protected
#undef private
#include "os.cc"

using namespace toit;

static bool locked, commit_ok;
static unsigned commits, decommits;
static uword expected_address, expected_size;
GcMetadata GcMetadata::singleton_;
static uint8 page_types[128];
static unsigned probe;
static uint8 expected_type;
static uint64 expected_bitmap;

void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "a chunk created for the claimed run is in the metadata range");
  abort();
}

void Locker::enter() {
  CXXV_ASSERT(!locked, "acquire the resource lock once");
  locked = true;
}
void Locker::leave() {
  CXXV_ASSERT(locked, "release the held resource lock");
  locked = false;
}
bool OS::use_virtual_memory(void* address, uword bytes) {
  ++commits;
  CXXV_ASSERT(locked && reinterpret_cast<uword>(address) == expected_address && bytes == expected_size,
              "commit exactly the free range under the resource lock");
  return commit_ok;
}
void OS::unuse_virtual_memory(void* address, uword bytes) {
  ++decommits;
  CXXV_ASSERT(locked && reinterpret_cast<uword>(address) == expected_address && bytes == expected_size,
              "decommit the same range under the resource lock");
  CXXV_ASSERT(toit_heap_bits[0] == UINT64_MAX && toit_heap_bits[1] == expected_bitmap &&
              page_types[probe] == expected_type, "reclassify the retired pages and release their bits before decommit");
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  unsigned count = nondet_uint(), offset = nondet_uint();
  CXXV_ASSUME(count >= 1 && count <= 64 && offset <= 64 - count);
  uint64 mask = count == 64 ? UINT64_MAX : ((uint64{1} << count) - 1) << offset;
  uint64 saved = ~mask;
  uint64 words[2] = {UINT64_MAX, saved};
  toit_heap_bits = words;
  toit_heap_range = reinterpret_cast<void*>(16 * TOIT_PAGE_SIZE);
  toit_heap_size = 128 * TOIT_PAGE_SIZE;
  expected_address = (16 + 64 + offset) * TOIT_PAGE_SIZE;
  expected_size = count * TOIT_PAGE_SIZE;
  commit_ok = false;
  void* result = OS::allocate_pages(expected_size);
  CXXV_ASSERT(!locked && result == nullptr && words[0] == UINT64_MAX && words[1] == saved && commits == 1,
              "commit failure leaves the original free run available");
  commit_ok = true;
  result = OS::allocate_pages(expected_size);
  CXXV_ASSERT(!locked && reinterpret_cast<uword>(result) == expected_address && commits == 2 &&
              words[0] == UINT64_MAX && words[1] == UINT64_MAX, "retry claims exactly the free run");
  CXXV_ASSERT(OS::allocate_pages(TOIT_PAGE_SIZE) == nullptr && commits == 2, "an exhausted range requests no commit");
  auto& meta = GcMetadata::singleton_;
  meta.lowest_address_ = reinterpret_cast<uword>(toit_heap_range);
  meta.heap_extent_ = toit_heap_size;
  meta.page_type_bytes_ = page_types;
  probe = nondet_uint() % ARRAY_SIZE(page_types);
  bool inside = 64 + offset <= probe && probe < 64 + offset + count;
  page_types[probe] = inside ? OLD_SPACE_PAGE : static_cast<uint8>(nondet_uint());
  expected_type = inside ? UNKNOWN_SPACE_PAGE : page_types[probe];
  expected_bitmap = saved;
  alignas(Chunk) uint8 storage[sizeof(Chunk)];
  Chunk* chunk = new (storage) Chunk(nullptr, reinterpret_cast<uword>(result), expected_size);
  chunk->~Chunk();
  CXXV_ASSERT(!locked && decommits == 1 && words[0] == UINT64_MAX && words[1] == saved,
              "release restores the initial page bitmap");
  CXXV_ASSERT(page_types[probe] == expected_type, "retirement preserves every neighboring page type");
}
