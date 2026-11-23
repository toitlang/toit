// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
// This path never constructs a mutex. Use the host declarations for that header.
#undef TOIT_FREERTOS
#include "mutex.h"
#define TOIT_FREERTOS
#define private public
#define protected public
#include "third_party/dartino/gc_metadata.h"
#undef protected
#undef private

namespace toit {
// The range decision is checked separately for every input in main.
class AdmissionMetadata : public GcMetadata {
 public:
  static bool contains_chunk(void* memory, uword size);
};
#define GcMetadata AdmissionMetadata
#include "chunk_admission.inc"
#undef GcMetadata
}

using namespace toit;
GcMetadata GcMetadata::singleton_;
extern Chunk descriptor;
extern OldSpace space;
static uword rounded;
static unsigned terminal_at, calls, releases, handoffs, queries;
static Space* owner;
static void *last_offer, *observed_offer;
static unsigned observed_index;
static bool out_of_pages;

void* OS::allocate_pages(uword bytes) {
  CXXV_ASSERT(rounded != 0 && bytes == rounded && releases == 0 && calls < 50 && calls <= terminal_at,
              "every attempt reserves the rounded extent before cleanup");
  uword address = nondet_uint();
  CXXV_ASSUME(address != 0 && address % TOIT_PAGE_SIZE == 0);
  last_offer = calls == terminal_at && out_of_pages ? nullptr : reinterpret_cast<void*>(address);
  if (calls == observed_index) observed_offer = last_offer;
  ++calls;
  return last_offer;
}

bool AdmissionMetadata::contains_chunk(void* memory, uword size) {
  ++queries;
  CXXV_ASSERT(memory && memory == last_offer && size == rounded && queries == calls,
              "test each nonnull reservation once with its complete extent");
  return calls - 1 == terminal_at;
}

void OS::free_pages(void* address, uword bytes) {
  CXXV_ASSERT(calls == (terminal_at == 50 ? 50 : terminal_at + 1) && releases < terminal_at && bytes == rounded &&
              (releases != observed_index || address == observed_offer),
              "release every rejected reservation in order");
  ++releases;
}

Chunk* ObjectMemory::allocate_chunk_helper(Space* supplied_owner, uword bytes, void* memory) {
  CXXV_ASSERT(calls == terminal_at + 1 && releases == terminal_at && handoffs == 0 && bytes == rounded &&
              queries == calls && memory && memory == last_offer && supplied_owner == owner,
              "hand off the terminal reservation after complete cleanup");
  ++handoffs;
  return memory ? &descriptor : nullptr;
}

int main() {
  static_assert(WORD_BIT_SIZE == 32 && TOIT_PAGE_SIZE == 4096, "embedded word and page sizes");
  uword bytes = nondet_uint(), address = nondet_uint(), lowest = nondet_uint(), extent = nondet_uint();
  auto& meta = GcMetadata::singleton_;
  meta.lowest_address_ = lowest;
  meta.heap_extent_ = extent;
  CXXV_ASSUME(static_cast<uint64>(lowest) + extent <= UINTPTR_MAX);
  bool contained = bytes && lowest <= address && static_cast<uint64>(address) + bytes <= static_cast<uint64>(lowest) + extent;
  CXXV_ASSERT(GcMetadata::contains_chunk(reinterpret_cast<void*>(address), bytes) == contained,
              "all occupied bytes lie inside the published metadata range");
  uint64 pages = (static_cast<uint64>(bytes) + TOIT_PAGE_SIZE - 1) / TOIT_PAGE_SIZE;
  rounded = pages * TOIT_PAGE_SIZE <= UINTPTR_MAX ? static_cast<uword>(pages * TOIT_PAGE_SIZE) : 0;
  // The first accepting decision or null result can occur at any attempt.
  // A terminal index of 50 means every reservation was rejected.
  // Observe any release position without imposing a pattern on OS addresses.
  observed_index = nondet_uint();
  CXXV_ASSUME(observed_index < 50);
  terminal_at = nondet_uint();
  CXXV_ASSUME(terminal_at <= 50);
  out_of_pages = nondet_bool();
  owner = nondet_bool() ? &space : nullptr;
  Chunk* result = ObjectMemory::allocate_chunk(owner, bytes);
  if (!rounded) {
    CXXV_ASSERT(result == nullptr && calls == 0 && releases == 0 && handoffs == 0,
                "zero and unrepresentable requests have no side effects");
  } else {
    bool exhausted = terminal_at == 50;
    bool accepted = !exhausted && !out_of_pages;
    CXXV_ASSERT(calls == (exhausted ? 50 : terminal_at + 1) &&
                queries == calls - (!exhausted && out_of_pages) && releases == terminal_at,
                "release all rejected pages including when the reservation limit is reached");
    CXXV_ASSERT(handoffs == static_cast<unsigned>(accepted) && result == (accepted ? &descriptor : nullptr),
                "only a range-checked reservation reaches the descriptor allocator");
  }
}
