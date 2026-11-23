// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#ifdef TOIT_FREERTOS
#undef TOIT_FREERTOS
#include "mutex.h"
#define TOIT_FREERTOS
#ifdef CXXV_ESP32
#define TOIT_ESP32
#endif
#endif
#define private public
#ifdef TOIT_FREERTOS
#define protected public
#include "third_party/dartino/object_memory.h"
#undef protected
static void* chunk_fill(void*, int, size_t);
#define memset chunk_fill
#endif
#include "third_party/dartino/gc_metadata.h"
#ifdef TOIT_FREERTOS
#undef memset
#endif
#include "heap_report.h"
#undef private

using namespace toit;

static OS::HeapMemoryRange heap;
static uint8* origin;
static uword allocation;
static uword capacity;
static uword commit_start[4];
static uword commit_size[4];
static unsigned commits;
static bool failed;
static bool initialized;
static word heap_tag;
static unsigned releases;
static bool duplicate_setup;
static bool invalid_range;

#ifdef CXXV_ESP32
bool OS::use_spiram_for_heap_;
bool OS::use_spiram_for_metadata_;
#endif
#ifdef TOIT_FREERTOS
static uword chunk_start, chunk_offset, chunk_bytes;
static unsigned lazy_commits, chunk_fills, page_releases;
static bool retiring;
extern OldSpace old_space;
extern SemiSpace young_space;
static PageType owner_kind;
static void* chunk_fill(void* address, int value, size_t count) {
  unsigned stage = chunk_fills++;
  uword base = allocation, scale = 8 * WORD_SIZE;
  int expected_value = 0;
  switch (stage) {
    case 0: base = commit_start[3]; scale = TOIT_PAGE_SIZE; expected_value = owner_kind; break;
    case 1: break;  // Mark bits.
    case 2: base = commit_start[2]; scale = 8 * GcMetadata::CARD_SIZE; break;
    case 3: base = commit_start[1]; scale = GcMetadata::CARD_SIZE; expected_value = GcMetadata::NO_OBJECT_START; break;
    case 4: base = commit_start[0]; scale = GcMetadata::CARD_SIZE; break;
    case 5: base = commit_start[3]; scale = TOIT_PAGE_SIZE; expected_value = UNKNOWN_SPACE_PAGE; break;
    default: CXXV_ASSERT(false, "unexpected chunk metadata fill");
  }
  CXXV_ASSERT(initialized && lazy_commits == 2 && retiring == (stage == 5) &&
              reinterpret_cast<uword>(address) == base + chunk_offset / scale &&
              count == chunk_bytes / scale && value == expected_value,
              "published tables supply the exact chunk slice and fill byte");
  return address;
}

void OS::free_pages(void* address, uword bytes) {
  CXXV_ASSERT(retiring && chunk_fills == 6 && !page_releases &&
              reinterpret_cast<uword>(address) == chunk_start && bytes == chunk_bytes,
              "unclassify the chunk in the published mapping before returning its reservation");
  ++page_releases;
}
#endif

static void check_unpublished() {
  uword address, bytes;
  GcMetadata::get_metadata_extent(&address, &bytes);
  CXXV_ASSERT(address == 0 && bytes == 0 && GcMetadata::heap_extent() == 0,
              "metadata remains unpublished during setup and after retirement");
}

word OS::get_heap_tag() { return heap_tag; }
void OS::set_heap_tag(word tag) { heap_tag = tag; }

OS::HeapMemoryRange OS::get_heap_memory_range() { return heap; }

void* OS::grab_virtual_memory(void* hint, uword size) {
  CXXV_ASSERT(!invalid_range && !duplicate_setup && hint == nullptr && size > 0 && size % TOIT_PAGE_SIZE == 0, "reserve whole metadata pages");
  check_unpublished();
  void* memory = nondet_bool() ? nullptr : malloc(size);
  origin = static_cast<uint8*>(memory);
  allocation = reinterpret_cast<uword>(memory);
  capacity = size;
  CXXV_ASSUME(allocation % WORD_SIZE == 0 && allocation <= UINTPTR_MAX - size);
  return memory;
}

bool OS::use_virtual_memory(void* address, uword size) {
#ifdef TOIT_FREERTOS
  if (chunk_bytes) {
    bool marks = lazy_commits++ == 0;
    uword scale = marks ? 8 * WORD_SIZE : 32;
    uword base = marks ? allocation : reinterpret_cast<uword>(GcMetadata::singleton_.cumulative_mark_bit_counts_);
    uword actual = reinterpret_cast<uword>(address);
    CXXV_ASSERT(initialized && lazy_commits <= 2 && !chunk_fills && actual == base + chunk_offset / scale &&
                size == chunk_bytes / scale + marks && actual >= allocation &&
                actual - allocation <= capacity && size <= capacity - (actual - allocation),
                "both lazy commits fit the published reservation, including the mark lookahead");
    return true;
  }
#endif
  check_unpublished();
  uword start = reinterpret_cast<uword>(address);
  CXXV_ASSERT(!failed && commits < 4, "stop on the first failed commit");
  CXXV_ASSERT(__ESBMC_same_object(address, origin), "commit only pages in the owned reservation");
  uword offset = static_cast<uint8*>(address) - origin;
  CXXV_ASSERT(size > 0 && size <= capacity && offset <= capacity - size, "commit only within the reserved extent");
  commit_start[commits] = start;
  commit_size[commits++] = size;
  failed = nondet_bool();
  return !failed;
}

void OS::ungrab_virtual_memory(void* address, uword bytes) {
  check_unpublished();
  CXXV_ASSERT(releases == 0 && allocation != 0 && reinterpret_cast<uword>(address) == allocation &&
              bytes == capacity && (initialized || failed), "release the exact owned reservation once");
  ++releases;
  free(address);
}

static void setup_abort() {
  check_unpublished();
  CXXV_ASSERT(capacity > 0 && !initialized && (allocation == 0 ? commits == 0 && releases == 0 : failed && releases == 1),
              "setup failure leaves no live metadata reservation");
  abort();
}

void toit::fail(const char*, ...) {
  if (invalid_range) {
    check_unpublished();
    CXXV_ASSERT(capacity == 0 && commits == 0 && releases == 0, "reject invalid heap ranges before reserving metadata");
    abort();
  }
  CXXV_ASSERT(duplicate_setup && initialized && releases == 0 &&
              reinterpret_cast<uword>(GcMetadata::singleton_.metadata_) == allocation,
              "a duplicate setup fails while preserving the active mapping");
  abort();
}

// Observe the single bulk fill in setup. The C library supplies its byte writes.
static void* check_fill(void* address, int value, size_t count) {
  CXXV_ASSERT(commits == 4 && !failed && reinterpret_cast<uword>(address) == commit_start[3] &&
              count == commit_size[3] && value == UNKNOWN_SPACE_PAGE, "initialize exactly the committed page-type table");
  check_unpublished();
  initialized = true;
  return address;
}
#define abort setup_abort
#define memset check_fill
#include "third_party/dartino/gc_metadata.cc"
#undef memset
#undef abort
#ifdef TOIT_FREERTOS
#include "third_party/dartino/object_memory.cc"
#endif

// Use the published backing allocation as the oracle, independently of
// the address calculation in either the write barrier or the reader.
static void check_card_write(uword first, uword address) {
  uword card_offset = commit_start[0] - allocation + (address - first) / GcMetadata::CARD_SIZE;
  uword witness = nondet_ulong();
  CXXV_ASSUME(witness < commit_start[3] - commit_start[0] + commit_size[3]);
  uword witness_offset = commit_start[0] - allocation + witness;
  uint8 before = nondet_uchar();
  origin[witness_offset] = before;
  uint8 old_card = nondet_uchar();
  origin[card_offset] = old_card;
  CXXV_ASSERT(GcMetadata::is_marked_dirty(address) == (old_card != GcMetadata::NO_NEW_SPACE_POINTERS),
              "read the previous value of the published card");
  GcMetadata::insert_into_remembered_set(address);
  CXXV_ASSERT(origin[card_offset] == GcMetadata::NEW_SPACE_POINTERS && GcMetadata::is_marked_dirty(address),
              "mark the selected byte in the committed remembered set");
  CXXV_ASSERT(witness_offset == card_offset || origin[witness_offset] == before,
              "preserve every other byte in the four committed tables");
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword low = nondet_ulong();
  uword first = low & ~static_cast<uword>(TOIT_PAGE_SIZE - 1);
  uword extent = nondet_ulong() & ~static_cast<uword>(TOIT_PAGE_SIZE - 1);
  uword bytes;
  invalid_range = nondet_bool();
  if (invalid_range) {
    bytes = nondet_ulong();
    uword highest_end = UINTPTR_MAX - (TOIT_PAGE_SIZE - 1);
    CXXV_ASSUME(bytes == 0 || low > highest_end || bytes > highest_end - low);
  } else {
    // Every valid interval ends within one page of its exclusive page limit.
    uword padding = nondet_ulong() % TOIT_PAGE_SIZE;
    CXXV_ASSUME(extent <= UINTPTR_MAX - first && extent > padding + (low - first));
    bytes = extent - padding - (low - first);
  }
  heap = {reinterpret_cast<void*>(low), bytes};
  word previous_tag = nondet_word();
  int heuristics = nondet_int();
  GcMetadata::set_large_heap_heuristics(heuristics);
  heap_tag = previous_tag;
#ifdef CXXV_ESP32
  OS::use_spiram_for_heap_ = nondet_bool();
  OS::use_spiram_for_metadata_ = nondet_bool();
  if (!OS::use_spiram_for_heap_ && !OS::use_spiram_for_metadata_) {
    uword retained = extent <= 148 * KB ? extent : extent < 256 * KB ? 148 * KB :
                     extent < 308 * KB ? 200 * KB : extent - 108 * KB;
    first += extent - retained;
    extent = retained;
  }
#endif
  GcMetadata::set_up();
  GcMetadata& metadata = GcMetadata::singleton_;
  CXXV_ASSERT(!invalid_range && initialized && !failed && allocation != 0, "return only with initialized and accessible tables");
  CXXV_ASSERT(metadata.lowest_address_ == first && metadata.heap_extent_ == extent, "cover the enclosing heap pages");

  CXXV_ASSERT(heap_tag == previous_tag, "restore the previous heap tag after reserving metadata");
  CXXV_ASSERT(metadata.heap_start_munged_ == first / 2 + (uword{1} << (WORD_BIT_SIZE - 1)) &&
              metadata.heap_extent_munged_ == extent / 2, "initialize the tagged page lookup bounds");
  uword marks = reinterpret_cast<uword>(metadata.mark_bits_);
  uword counts = reinterpret_cast<uword>(metadata.cumulative_mark_bit_counts_);
  CXXV_ASSERT(marks == allocation && counts >= marks && counts - marks >= extent / (8 * WORD_SIZE) &&
              counts % WORD_SIZE == 0, "a full aligned mark table precedes the destination table");
  CXXV_ASSERT(commit_start[0] >= counts && commit_start[0] - counts >= extent / 32,
              "the destination table has one word per heap card");
  CXXV_ASSERT(commit_size[0] >= extent / GcMetadata::CARD_SIZE && commit_size[1] >= extent / GcMetadata::CARD_SIZE &&
              commit_size[2] >= extent / (8 * GcMetadata::CARD_SIZE) && commit_size[3] >= extent / TOIT_PAGE_SIZE,
              "the eager tables cover every heap card and page");
  CXXV_ASSERT(commit_start[0] + commit_size[0] == commit_start[1] &&
              commit_start[1] + commit_size[1] == commit_start[2] &&
              commit_start[2] + commit_size[2] == commit_start[3], "the four committed tables are consecutive and disjoint");
  CXXV_ASSERT(metadata.mark_bits_bias_ == marks - first / (8 * WORD_SIZE) &&
              metadata.cumulative_mark_bits_bias_ == counts - first / 32 &&
              metadata.remembered_set_bias_ == commit_start[0] - first / GcMetadata::CARD_SIZE &&
              metadata.starts_bias_ == commit_start[1] - first / GcMetadata::CARD_SIZE &&
              metadata.overflow_bits_bias_ == commit_start[2] - first / (8 * GcMetadata::CARD_SIZE) &&
              reinterpret_cast<uword>(metadata.page_type_bytes_) == commit_start[3],
              "install each table at the bias used by the native accessors");
  uword probe = nondet_ulong();
  uword end = first + extent;
  CXXV_ASSERT(GcMetadata::in_metadata_range(probe) == (first <= probe && probe <= end),
              "the published range includes its endpoint for one-past table lookups");
  if (first <= probe && probe <= end) {
    uword card = (probe - first) / GcMetadata::CARD_SIZE;
    CXXV_ASSERT(reinterpret_cast<uword>(GcMetadata::starts_for(probe)) == commit_start[1] + card &&
                reinterpret_cast<uword>(GcMetadata::remembered_set_for(probe)) == commit_start[0] + card &&
                reinterpret_cast<uword>(GcMetadata::overflow_bits_for(probe)) == commit_start[2] + card / 8,
                "native accessors select the committed table bytes or their logical end");
    if (probe < end) {
      CXXV_ASSERT(card < commit_size[0] && card < commit_size[1] && card / 8 < commit_size[2],
                  "every interior address indexes committed storage");
      check_card_write(first, probe);
    }
  }
  duplicate_setup = nondet_bool();
  if (duplicate_setup) {
    GcMetadata::set_up();
    CXXV_ASSERT(false, "duplicate setup cannot return");
  }
  uword published, published_size;
  GcMetadata::get_metadata_extent(&published, &published_size);
  CXXV_ASSERT(published == allocation && published_size == capacity, "publish the complete metadata reservation");
#ifdef TOIT_FREERTOS
  static_assert(WORD_BIT_SIZE == 32 && TOIT_PAGE_SIZE == 4096, "embedded metadata layout");
  // Use an arbitrary live chunk supplied by the page provider, including
  // either endpoint of the retained interval. Keep the actual setup biases.
  chunk_offset = (nondet_uint() / TOIT_PAGE_SIZE) * TOIT_PAGE_SIZE;
  chunk_bytes = (nondet_uint() / TOIT_PAGE_SIZE) * TOIT_PAGE_SIZE;
  CXXV_ASSUME(chunk_offset < extent && chunk_bytes > 0 && chunk_bytes <= extent - chunk_offset);
  chunk_start = first + chunk_offset;
  alignas(Chunk) uint8 descriptor[sizeof(Chunk)];
  Chunk* chunk = new (descriptor) Chunk(nullptr, chunk_start, chunk_bytes);
  GcMetadata::map_metadata_for_chunk(chunk);
  old_space.page_type_ = OLD_SPACE_PAGE;
  young_space.page_type_ = NEW_SPACE_PAGE;
  Space* owner = nondet_bool() ? static_cast<Space*>(&old_space) : static_cast<Space*>(&young_space);
  owner_kind = owner->page_type();
  chunk->set_owner(owner);
  CXXV_ASSERT(chunk->owner() == owner && chunk_fills == 5, "publish an initialized young or old chunk");
  retiring = true;
  chunk->~Chunk();
  CXXV_ASSERT(page_releases == 1, "retire the selected heap pages before withdrawing the tables");
#endif
  GcMetadata::tear_down();
  GcMetadata::tear_down();
  check_unpublished();
  CXXV_ASSERT(releases == 1 && GcMetadata::large_heap_heuristics() == heuristics && metadata.page_type_bytes_ == nullptr && metadata.mark_bits_ == nullptr &&
              metadata.cumulative_mark_bit_counts_ == nullptr && metadata.object_starts_ == nullptr &&
              metadata.remembered_set_ == nullptr && metadata.mark_stack_overflow_bits_ == nullptr,
              "retirement clears all six table pointers and repeated teardown cannot free again");
}
