// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#ifdef TOIT_FREERTOS
// The harness uses no mutex objects or lock operations.
#undef TOIT_FREERTOS
#include "mutex.h"
#define TOIT_FREERTOS
#endif
#define private public
#define protected public
#include "third_party/dartino/object_memory.h"
static void record_fill(void*, int, size_t);
#define memset record_fill
#include "third_party/dartino/gc_metadata.h"
#undef memset
#undef protected
#undef private

using namespace toit;

static bool descriptor_failure;
static unsigned descriptors;
static unsigned rejected, releases;
// The VM's nothrow allocator returns malloc storage. Construct directly in
// that storage so the intrusive links refer to the published descriptor.
static void* descriptor_storage;
static bool reserve_descriptor() {
  CXXV_ASSERT(releases == rejected, "release rejected reservations before allocating a descriptor");
  ++descriptors;
  if (descriptor_failure) return false;
  descriptor_storage = malloc(sizeof(Chunk));
  CXXV_ASSUME(descriptor_storage != nullptr);
  return true;
}

#undef _new
#define _new !reserve_descriptor() ? nullptr : new (descriptor_storage)
#include "object_memory.inc"
#undef _new

GcMetadata GcMetadata::singleton_;
extern OldSpace space;
extern SemiSpace young_space;
static constexpr uword HEAP_BASE = 16 * TOIT_PAGE_SIZE;
static constexpr uword MAX_SIZE = 64 * TOIT_PAGE_SIZE;
static bool page_failure;
static unsigned reservations, commits;
static unsigned refused_commit;
static uword before, reserved_size, offset_bytes;

static uint8 page_types[MAX_SIZE / TOIT_PAGE_SIZE];
static uint8 marks_and_counts[MAX_SIZE / (8 * WORD_SIZE) + 1 + MAX_SIZE / 32];
static uint8 starts[MAX_SIZE / GcMetadata::CARD_SIZE];
static uint8 remembered[sizeof(starts)];
static uint8 overflow[sizeof(starts) / 8];
static unsigned fills;
static bool retiring;
static unsigned observed_offset;
static PageType original_kind, allocated_kind;

static void check_page_kind(PageType kind) {
  uword raw = HEAP_BASE + (observed_offset & ~uword{1});
  Object* tagged = reinterpret_cast<Object*>(raw + 1);
  CXXV_ASSERT(GcMetadata::get_page_type(raw) == kind && GcMetadata::get_page_type(tagged) == kind,
              "the GC observes the expected classification at every mapped address");
}

static unsigned descriptor_frees;
void operator delete(void* storage) noexcept {
  CXXV_ASSERT(retiring && storage == descriptor_storage && releases == rejected + 1 &&
              fills == 1 && ObjectMemory::allocated() == before && !descriptor_frees,
              "free the original descriptor after unclassifying, uncharging and releasing its pages");
  ++descriptor_frees;
  free(storage);
}

static uword rejected_address() {
  return HEAP_BASE + MAX_SIZE - (reserved_size > TOIT_PAGE_SIZE ? TOIT_PAGE_SIZE : 0);
}

void toit::fail(const char*, ...) {
  CXXV_ASSERT(refused_commit != 0 && commits == refused_commit && descriptors == 1 &&
              descriptor_storage != nullptr && reservations == rejected + 1 && releases == rejected &&
              fills == 0 && ObjectMemory::allocated() == before,
              "a refused commit stops allocation before initialization, publication or charging");
  // The process terminates with the descriptor still live. Release the
  // observer's malloc storage for the model checker's terminal leak check.
  free(descriptor_storage);
  abort();
}

static void record_fill(void* address, int value, size_t bytes) {
  unsigned bit = 0;
  if (address == page_types + offset_bytes / TOIT_PAGE_SIZE) {
    bit = 1;
    CXXV_ASSERT(!retiring || ObjectMemory::allocated() == before, "uncharge before retiring the classification");
    CXXV_ASSERT(bytes == reserved_size / TOIT_PAGE_SIZE && value == (retiring ? UNKNOWN_SPACE_PAGE : allocated_kind),
                "classify exactly the supplied pages");
    // Project the memset contract onto one arbitrary page-table byte.
    unsigned index = observed_offset / TOIT_PAGE_SIZE;
    size_t first = static_cast<uint8*>(address) - page_types;
    if (index >= first && index - first < bytes) page_types[index] = static_cast<uint8>(value);
  } else if (address == marks_and_counts + offset_bytes / (8 * WORD_SIZE)) {
    bit = 2;
    CXXV_ASSERT(bytes == reserved_size / (8 * WORD_SIZE) && value == 0, "clear the mark bits for the chunk");
  } else if (address == starts + offset_bytes / GcMetadata::CARD_SIZE) {
    bit = 4;
    CXXV_ASSERT(bytes == reserved_size / GcMetadata::CARD_SIZE && value == GcMetadata::NO_OBJECT_START,
                "reset each object-start entry");
  } else if (address == remembered + offset_bytes / GcMetadata::CARD_SIZE) {
    bit = 8;
    CXXV_ASSERT(bytes == reserved_size / GcMetadata::CARD_SIZE && value == GcMetadata::NO_NEW_SPACE_POINTERS,
                "reset each remembered-set entry");
  } else if (address == overflow + offset_bytes / (8 * GcMetadata::CARD_SIZE)) {
    bit = 16;
    CXXV_ASSERT(bytes == reserved_size / (8 * GcMetadata::CARD_SIZE) && value == 0, "clear each overflow byte");
  }
  CXXV_ASSERT(bit && !(fills & bit) && commits == 2, "initialize each expected table once after mapping");
  fills |= bit;
}

void* OS::allocate_pages(uword size) {
  ++reservations;
  CXXV_ASSERT(size == reserved_size && ObjectMemory::allocated() == before, "reserve the rounded extent before charging");
  if (reservations <= rejected) return reinterpret_cast<void*>(rejected_address());
  return (page_failure || size > MAX_SIZE) ? nullptr : reinterpret_cast<void*>(HEAP_BASE + offset_bytes);
}
void OS::free_pages(void* address, uword size) {
  check_page_kind(original_kind);
  ++releases;
  if (releases <= rejected) {
    CXXV_ASSERT(reinterpret_cast<uword>(address) == rejected_address() && size == reserved_size && !descriptors &&
                !commits && !fills && ObjectMemory::allocated() == before, "return the rejected block intact before handoff");
    return;
  }
  CXXV_ASSERT(reinterpret_cast<uword>(address) == HEAP_BASE + offset_bytes && size == reserved_size, "release the complete reservation");
  CXXV_ASSERT(ObjectMemory::allocated() == before && fills == (retiring ? 1u : 0u),
              "release after restoring the charge and retiring any page classification");
}
bool OS::use_virtual_memory(void* address, uword size) {
  ++commits;
  CXXV_ASSERT(ObjectMemory::allocated() == before, "commit metadata before charging the chunk");
  uword table = reinterpret_cast<uword>(marks_and_counts);
  uword start = reinterpret_cast<uword>(address);
  uword offset = start - table;
  CXXV_ASSERT(start >= table && offset <= sizeof(marks_and_counts) && size <= sizeof(marks_and_counts) - offset,
              "each commit stays inside the metadata reservation");
  uword first = commits == 1 ? offset_bytes / (8 * WORD_SIZE) : MAX_SIZE / (8 * WORD_SIZE) + 1 + offset_bytes / 32;
  uword bytes = commits == 1 ? reserved_size / (8 * WORD_SIZE) + 1 : reserved_size / 32;
#ifdef TOIT_FREERTOS
  CXXV_ASSERT(offset == first && size == bytes, "embedded commits use the exact metadata slices");
#endif
  CXXV_ASSERT(offset <= first && first - offset <= size && bytes <= size - (first - offset),
              "commit covers the mark lookahead byte or the entire cumulative-mark slice");
  return commits != refused_commit;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  page_failure = nondet_bool();
  descriptor_failure = nondet_bool();
  refused_commit = nondet_uint() % 3;
  uword bytes = nondet_ulong();
  uword pages = bytes / TOIT_PAGE_SIZE + (bytes % TOIT_PAGE_SIZE != 0);
  bool representable = pages != 0 && pages <= UINTPTR_MAX / TOIT_PAGE_SIZE;
  reserved_size = representable ? pages * TOIT_PAGE_SIZE : 0;
  bool page_refused = page_failure || reserved_size > MAX_SIZE;
#ifdef TOIT_FREERTOS
  static_assert(WORD_BIT_SIZE == 32 && TOIT_PAGE_SIZE == 4096, "embedded layout");
  rejected = representable && reserved_size <= MAX_SIZE && nondet_bool() ? 1 : 0;
#endif
  if (!page_refused && representable) {
    unsigned first_page = nondet_uint();
    CXXV_ASSUME(first_page <= (MAX_SIZE - reserved_size) / TOIT_PAGE_SIZE);
    offset_bytes = first_page * TOIT_PAGE_SIZE;
  }

  before = nondet_ulong();
  CXXV_ASSUME(page_refused || descriptor_failure || refused_commit != 0 || before <= UINTPTR_MAX - reserved_size);
  ObjectMemory::allocated_ = before;

  auto& meta = GcMetadata::singleton_;
  meta.lowest_address_ = HEAP_BASE;
  meta.heap_extent_ = MAX_SIZE;
  meta.page_type_bytes_ = page_types;
  meta.heap_start_munged_ = HEAP_BASE / 2 + (uword{1} << (WORD_BIT_SIZE - 1));
  meta.heap_extent_munged_ = MAX_SIZE / 2;
  observed_offset = nondet_uint() % MAX_SIZE;
  bool in_chunk = observed_offset >= offset_bytes && observed_offset - offset_bytes < reserved_size;
  original_kind = in_chunk ? UNKNOWN_SPACE_PAGE : static_cast<PageType>(nondet_uint() % 3);
  page_types[observed_offset / TOIT_PAGE_SIZE] = original_kind;
  meta.mark_bits_bias_ = reinterpret_cast<uword>(marks_and_counts) - HEAP_BASE / (8 * WORD_SIZE);
  meta.starts_bias_ = reinterpret_cast<uword>(starts) - HEAP_BASE / GcMetadata::CARD_SIZE;
  meta.remembered_set_bias_ = reinterpret_cast<uword>(remembered) - HEAP_BASE / GcMetadata::CARD_SIZE;
  meta.overflow_bits_bias_ = reinterpret_cast<uword>(overflow) - HEAP_BASE / (8 * GcMetadata::CARD_SIZE);
  meta.metadata_ = marks_and_counts;
  meta.metadata_size_ = sizeof(marks_and_counts);
  meta.cumulative_mark_bits_bias_ = reinterpret_cast<uword>(marks_and_counts) + MAX_SIZE / (8 * WORD_SIZE) + 1 - HEAP_BASE / 32;

  space.page_type_ = OLD_SPACE_PAGE;
  young_space.page_type_ = NEW_SPACE_PAGE;
  Space* owner = nullptr;
  if (nondet_bool()) owner = nondet_bool() ? static_cast<Space*>(&space) : static_cast<Space*>(&young_space);
  allocated_kind = owner ? owner->page_type() : UNKNOWN_SPACE_PAGE;
  Chunk* chunk = ObjectMemory::allocate_chunk(owner, bytes);
  if (!representable) {
    CXXV_ASSERT(chunk == nullptr && reservations == 0 && descriptors == 0 && commits == 0 &&
                fills == 0 && releases == 0 && ObjectMemory::allocated() == before,
                "zero and unrepresentable extents leave all allocation state untouched");
    return 0;
  }
  CXXV_ASSERT(reservations == rejected + 1 && descriptors == (page_refused ? 0 : 1), "descriptor allocation follows page admission");
  if (page_refused || descriptor_failure) {
    CXXV_ASSERT(chunk == nullptr && fills == 0 && commits == 0 && releases == rejected + (page_refused ? 0 : 1) &&
                ObjectMemory::allocated() == before, "both failure paths balance pages and leave accounting intact");
    return 0;
  }
  CXXV_ASSERT(refused_commit == 0, "allocation cannot return after a refused metadata commit");
  CXXV_ASSERT(chunk != nullptr && chunk->owner() == owner && chunk->start() == HEAP_BASE + offset_bytes &&
              chunk->size() == reserved_size && chunk->scavenge_pointer() == HEAP_BASE + offset_bytes,
              "publish a descriptor for exactly the reserved range");
  CXXV_ASSERT(chunk->next_ == chunk && chunk->prev_ == chunk, "publish a detached descriptor");
  CXXV_ASSERT(commits == 2 && releases == rejected && ObjectMemory::allocated() == before + reserved_size,
              "successful allocation charges once after committing both metadata ranges");
  CXXV_ASSERT(fills == (owner ? 31u : 0u), "initialize all tables for owned chunks");
  check_page_kind(in_chunk ? allocated_kind : original_kind);
  retiring = true;
  fills = 0;
  ObjectMemory::free_chunk(chunk);
  CXXV_ASSERT(ObjectMemory::allocated() == before && releases == rejected + 1 && fills == 1 && descriptor_frees == 1,
              "successful allocation and retirement balance both page and descriptor ownership");
}
