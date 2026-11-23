// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "heap.cc"
#include "third_party/dartino/two_space_heap.cc"
#include "third_party/dartino/object_memory_copying.cc"
#undef protected
#undef private

namespace toit {
#include "old_chunk_expansion.inc"
}

using namespace toit;

static const Space* young_space;
extern Chunk new_chunk;
static OldSpace* space;
static uword old_bytes, young_bytes, request, expected_chunk, payload;
static bool page_failure;
static unsigned installs, reservations;

uword Space::size() const {
  if (this == space) return old_bytes;
  CXXV_ASSERT(this == young_space, "read the same process's young reservation");
  return young_bytes;
}

// The installer and the bump allocator each have a separation-logic proof.
// Supply their window effects and verify the arguments at the two call sites.
Chunk* OldSpace::allocate_and_use_chunk(uword size) {
  ++installs;
  CXXV_ASSERT(this == space && installs == 1 && size == expected_chunk && size != 0,
              "install exactly the admitted number of pages once");
  if (page_failure) return nullptr;
  const uword base = TOIT_PAGE_SIZE;
  top_ = base + (tracking_allocations_ ? PromotedTrack::HEADER_SIZE : 0);
  limit_ = base + size - WORD_SIZE;
  used_ += size - WORD_SIZE;
  old_bytes += size;  // Space::size counts the whole linked chunk, including its sentinel.
  return &new_chunk;
}
uword OldSpace::allocate(uword size) {
  ++reservations;
  CXXV_ASSERT(this == space && reservations == 1 && installs == 1 && !page_failure &&
              size == request && top_ == payload && size <= limit_ - top_,
              "retry the original request in the installed window with room for the sentinel");
  top_ += size;
  return payload;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  ObjectHeap process_heap(nullptr, nullptr, nullptr, nullptr, nullptr);
  auto& heap = process_heap.two_space_heap_;
  young_space = heap.new_space();
  space = &heap.old_space_;
  old_bytes = nondet_ulong();
  young_bytes = nondet_ulong();
  CXXV_ASSUME(old_bytes <= UINTPTR_MAX - young_bytes);
  uword external = nondet_ulong();
  process_heap.external_memory_.store(external);
  word limit = nondet_word();
  process_heap.limit_ = limit;
  process_heap.max_heap_size_ = nondet_word();
  bool tracking = nondet_bool(), stopped = nondet_bool(), prior_malloc_failure = nondet_bool();
  space->tracking_allocations_ = tracking;
  space->promotion_failed_ = stopped;
  heap.malloc_failed_ = prior_malloc_failure;
  space->limit_ = space->top_ = 0;
  uword used = nondet_ulong();
  CXXV_ASSUME(used <= old_bytes);
  space->used_ = used;
  request = nondet_ulong();
  CXXV_ASSUME(request >= WORD_SIZE && request % WORD_SIZE == 0);
  page_failure = nondet_bool();

  // The mathematical sum also covers an external charge that would wrap a word.
#if CXXV_WORD_BITS == 32
  using Wide = uint64;
#else
  using Wide = unsigned __int128;
#endif
  Wide charged = static_cast<Wide>(old_bytes) + young_bytes + external;
  bool unlimited = limit == 0 && process_heap.max_heap_size_ == 0;
  word allowance = process_heap.max_external_allocation();
  word expected_allowance = unlimited ? ObjectHeap::_UNLIMITED_EXPANSION :
      limit < 0 || charged > static_cast<uword>(limit) ? -1 : limit - static_cast<word>(charged);
  CXXV_ASSERT(allowance == expected_allowance, "derive expansion headroom from both spaces and the external charge");

  // The separate capacity proof covers the page calculation for all inputs.
  // Check that the expansion caller supplies those inputs and honors the result.
  uword budget = allowance > 0 ? static_cast<uword>(allowance) : 0;
  uword capacity = budget / TOIT_PAGE_SIZE * TOIT_PAGE_SIZE;
  uword overhead = WORD_SIZE + (tracking ? PromotedTrack::HEADER_SIZE : 0);
  bool admitted = !stopped && static_cast<Wide>(request) + overhead <= capacity;
  expected_chunk = promotion_chunk_size(request, tracking, Space::get_default_chunk_size(used), allowance);
  CXXV_ASSERT(expected_chunk <= capacity, "installed pages fit within the process expansion allowance");
  bool success = admitted && !page_failure;
  // On success the acquired pages coexist with the previously reserved heap.
  CXXV_ASSUME(!success || expected_chunk <= UINTPTR_MAX - old_bytes - young_bytes);
  payload = TOIT_PAGE_SIZE + (tracking ? PromotedTrack::HEADER_SIZE : 0);
  uword result = space->allocate_in_new_chunk(request);
  CXXV_ASSERT(installs == unsigned(admitted) && reservations == unsigned(success) && result == (success ? payload : 0),
              "publish exactly one installed reservation or return zero");
  CXXV_ASSERT(heap.malloc_failed_ == (prior_malloc_failure || (admitted && page_failure)) &&
              space->promotion_failed_ == !success, "distinguish budget rejection from provider failure and retain failure flags");
  CXXV_ASSERT(space->used_ == (success ? used + expected_chunk - WORD_SIZE : used) &&
              space->top_ == (success ? payload + request : 0), "only successful expansion consumes heap space");
  if (success) {
    word remaining = process_heap.max_external_allocation();
    CXXV_ASSERT(remaining >= 0 && static_cast<uword>(remaining) == (unlimited ? budget : budget - expected_chunk),
                "a bounded process loses exactly the linked page bytes from its expansion allowance");
  }
  exit(0);  // The modeled chunk outlives the check.
}
