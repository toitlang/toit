// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/object_memory.h"
static void fill_table(void*, int, size_t);
#define memset fill_table
#include "third_party/dartino/gc_metadata.h"
#undef memset
#include "third_party/dartino/object_memory.cc"
#include "third_party/dartino/object_memory_copying.cc"
// Supply the page-provider contract to the old-space implementation. The
// descriptor, ownership change, metadata tables and installer are production code.
namespace toit {
class InstallPageProvider : public ObjectMemory {
 public:
  static Chunk* allocate_chunk(Space* owner, uword bytes);
};
}
#define ObjectMemory InstallPageProvider
#include "third_party/dartino/object_memory_mark_sweep.cc"
#undef ObjectMemory
#undef protected
#undef private

using namespace toit;

static constexpr uword CARDS = TOIT_PAGE_SIZE / GcMetadata::CARD_SIZE;
alignas(TOIT_PAGE_SIZE) static uword page[TOIT_PAGE_SIZE / WORD_SIZE];
static constexpr uword MARK_BYTES = TOIT_PAGE_SIZE / (8 * WORD_SIZE);
static uint8 starts[CARDS], remembered[CARDS], marks[MARK_BYTES];
static uint8 overflow[CARDS / 8], page_type[1];
GcMetadata GcMetadata::singleton_;
// Observe libc at the first card and at an arbitrary other entry. Validate
// the entire destination interval even when only those bytes are observed.
static unsigned probe;
static void fill_table(void* p, int value, size_t count) {
  CXXV_ASSERT((p == starts && count == sizeof(starts) && value == GcMetadata::NO_OBJECT_START) ||
              (p == remembered && count == sizeof(remembered) && value == GcMetadata::NO_NEW_SPACE_POINTERS) ||
              (p == marks && count == MARK_BYTES && value == 0) ||
              (p == overflow && count == sizeof(overflow) && value == 0) ||
              (p == page_type && count == 1 && value == OLD_SPACE_PAGE), "clear exactly the chunk's metadata table");
  auto* table = static_cast<uint8*>(p);
  table[0] = value;
  if (probe < count) table[probe] = value;
}
static bool fail_page;
static unsigned requests;
static Chunk* offered;

Chunk* InstallPageProvider::allocate_chunk(Space* owner, uword bytes) {
  ++requests;
  CXXV_ASSERT(owner == offered->owner() && bytes == sizeof(page), "request one complete page for its owner");
  return fail_page ? nullptr : offered;
}
void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "the supplied page and tables cover this chunk");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  OldSpace space(nullptr, nullptr);
  uword base = reinterpret_cast<uword>(page);
  CXXV_ASSUME(base != 0 && base % TOIT_PAGE_SIZE == 0 && base <= INTPTR_MAX - sizeof(page));
  auto& meta = GcMetadata::singleton_;
  meta.lowest_address_ = base;
  meta.heap_extent_ = sizeof(page);
  meta.page_type_bytes_ = page_type;
  meta.overflow_bits_bias_ = reinterpret_cast<uword>(overflow) - base / (8 * GcMetadata::CARD_SIZE);
  meta.starts_bias_ = reinterpret_cast<uword>(starts) - base / GcMetadata::CARD_SIZE;
  meta.remembered_set_bias_ = reinterpret_cast<uword>(remembered) - base / GcMetadata::CARD_SIZE;
  meta.mark_bits_bias_ = reinterpret_cast<uword>(marks) - base / (8 * WORD_SIZE);
  Chunk chunk(&space, base, sizeof(page));
  offered = &chunk;
  bool tracking = nondet_bool();
  uword prior_header[3];
  auto* previous = tracking && nondet_bool()
      ? reinterpret_cast<PromotedTrack*>(HeapObject::from_address(reinterpret_cast<uword>(prior_header))) : nullptr;
  space.promoted_track_ = previous;
  space.tracking_allocations_ = tracking;
  uword used = nondet_ulong();
  CXXV_ASSUME(used <= UINTPTR_MAX - sizeof(page));
  space.used_ = used;
  fail_page = nondet_bool();
  probe = nondet_uint();
  CXXV_ASSUME(probe < CARDS);
  starts[probe] = remembered[probe] = marks[probe] = 99;
  starts[0] = 123;
  remembered[0] = 127;
  constexpr uword last_word = sizeof(page) / WORD_SIZE - 1;
  page[last_word] = 17;
  Chunk* result = space.allocate_and_use_chunk(sizeof(page));
  CXXV_ASSERT(requests == 1 && (!fail_page || result == nullptr), "page admission precedes publication");
  if (result == nullptr) {
    CXXV_ASSERT(fail_page && space.is_empty() && space.top_ == 0 && space.limit_ == 0 &&
                space.used_ == used && space.promoted_track_ == previous && page[last_word] == 17 && remembered[0] == 127 && starts[0] == 123,
                "failure preserves the window, charge and metadata");
  } else {
    CXXV_ASSERT(result == &chunk && result->owner() == &space && page_type[0] == OLD_SPACE_PAGE &&
                space.chunk_list_.first() == result && space.chunk_list_.last() == result,
                "publish the acquired descriptor");
    CXXV_ASSERT(space.top_ == base + (tracking ? PromotedTrack::HEADER_SIZE : 0) &&
                space.limit_ == base + sizeof(page) - WORD_SIZE && page[last_word] == 0 &&
                space.used_ == used + sizeof(page) - WORD_SIZE, "install the payload window, sentinel and exact charge");
    if (tracking) {
      auto* track = space.promoted_track_;
      CXXV_ASSERT(track != nullptr && track->_raw() == base && track->next() == previous &&
                  track->start() == space.top_ && track->end() == space.limit_,
                  "link the new promotion track over the full usable range");
    } else {
      CXXV_ASSERT(space.promoted_track_ == previous, "ordinary installation preserves the promotion list");
    }
    CXXV_ASSERT(marks[probe] == 0 && (probe == 0 || (starts[probe] == GcMetadata::NO_OBJECT_START &&
                remembered[probe] == GcMetadata::NO_NEW_SPACE_POINTERS)), "clear the remaining card entries");
    CXXV_ASSERT(remembered[0] == (tracking ? GcMetadata::NEW_SPACE_POINTERS : GcMetadata::NO_NEW_SPACE_POINTERS) &&
                starts[0] == (tracking ? base % 256 : GcMetadata::NO_OBJECT_START),
                "preserve the promotion header's dirty card and recorded start after installation");
  }
  exit(0);  // The fixture owns the descriptor and backing page.
}
