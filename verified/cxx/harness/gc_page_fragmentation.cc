// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "os.cc"

using namespace toit;

static uword base;
static uint64 original[2];
static uword requested;
static bool commit_ok;
static unsigned commits, decommits;
static void* committed;

void Locker::enter() {}
void Locker::leave() {}

bool OS::use_virtual_memory(void* address, uword bytes) {
  ++commits;
  committed = address;
  CXXV_ASSERT(bytes == requested && toit_heap_bits[0] == original[0] && toit_heap_bits[1] == original[1],
              "commit the complete request before publishing its bits");
  return commit_ok;
}

void OS::unuse_virtual_memory(void* address, uword bytes) {
  ++decommits;
  CXXV_ASSERT(address == committed && bytes == requested, "decommit the complete selected run");
}

// The single-word contract used by the unbounded bitmap scan.
static void check_word() {
  uint64 bits = static_cast<uint64>(nondet_int64());
  unsigned pages = nondet_uint();
  CXXV_ASSUME(1 <= pages && pages <= 64);
  unsigned start = nondet_uint();
  CXXV_ASSUME(start <= 64 - pages);
  uint64 span = UINT64_MAX >> (64 - pages);
  unsigned bit = nondet_uint();
  CXXV_ASSUME(bit < 64);
  CXXV_ASSERT(((page_run_mask(pages, start) >> bit) & 1) == (start <= bit && bit < start + pages),
              "the native mask covers exactly the requested interval");
  unsigned result = free_page_offset(bits, pages);
  CXXV_ASSERT(result == 64 || (result <= 64 - pages && ((bits >> result) & span) == 0),
              "return a fitting run or the end of the word");
  CXXV_ASSERT(((bits >> start) & span) != 0 || result <= start, "never skip an earlier fitting run");
}

int main() {
  check_word();
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  original[0] = static_cast<uint64>(nondet_int64());
  original[1] = static_cast<uint64>(nondet_int64());
  uint64 bitmap[] = {original[0], original[1]};
  toit_heap_bits = bitmap;
  toit_heap_size = 128 * TOIT_PAGE_SIZE;
  base = nondet_ulong();
  CXXV_ASSUME(base != 0 && base % TOIT_PAGE_SIZE == 0 && base <= UINTPTR_MAX - toit_heap_size);
  toit_heap_range = reinterpret_cast<void*>(base);

  uword invalid_size = nondet_ulong();
  CXXV_ASSUME(invalid_size == 0 || invalid_size > 64 * TOIT_PAGE_SIZE || invalid_size % TOIT_PAGE_SIZE != 0);
  CXXV_ASSERT(OS::allocate_pages(invalid_size) == nullptr && commits == 0 &&
              bitmap[0] == original[0] && bitmap[1] == original[1],
              "reject out-of-contract sizes before committing or changing the bitmap");

  unsigned count = nondet_uint();
  CXXV_ASSUME(1 <= count && count <= 64);
  requested = count * TOIT_PAGE_SIZE;
  // Any legal starting page can witness a missed or earlier free run.
  unsigned candidate_word = nondet_bool() ? 1 : 0;
  unsigned candidate = nondet_uint();
  CXXV_ASSUME(candidate <= 64 - count);
  uint64 span = UINT64_MAX >> (64 - count);
  bool candidate_free = ((original[candidate_word] >> candidate) & span) == 0;
  commit_ok = nondet_bool();
  void* result = OS::allocate_pages(requested);
  if (commits == 0) {
    CXXV_ASSERT(result == nullptr && !candidate_free && bitmap[0] == original[0] && bitmap[1] == original[1],
                "exhaustion implies every possible run intersects an occupied page");
  } else {
    uword address = reinterpret_cast<uword>(committed);
    CXXV_ASSERT(commits == 1 && result == (commit_ok ? committed : nullptr) && address >= base &&
                (address - base) % TOIT_PAGE_SIZE == 0, "return the committed page boundary");
    uword page = (address - base) / TOIT_PAGE_SIZE;
    CXXV_ASSERT(page < 128 && page % 64 <= 64 - count &&
                (!candidate_free || page <= candidate_word * 64 + candidate),
                "select the first fitting run");
    unsigned word_index = page / 64;
    uint64 claimed = span << (page % 64);
    CXXV_ASSERT((original[word_index] & claimed) == 0, "every page selected for commit was free");
    if (commit_ok) {
      CXXV_ASSERT(bitmap[word_index] == (original[word_index] | claimed) &&
                  bitmap[1 - word_index] == original[1 - word_index],
                  "claim every page of the run and preserve all other bits");
      OS::free_pages(result, requested);
    }
    CXXV_ASSERT(bitmap[0] == original[0] && bitmap[1] == original[1] && decommits == (commit_ok ? 1 : 0),
                "both a failed commit and release after success restore the complete bitmap");
  }
}
