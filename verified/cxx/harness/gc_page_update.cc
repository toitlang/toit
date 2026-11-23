// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "os.h"

namespace toit {
#include "heap_page_scan.h"

static uword selected, word_count;
static unsigned count;
static uint64* table;

// Supply the outcome of the separately verified first-fit scan.
static uword scanned_page(const uint64* bits, uword words, unsigned pages) {
  CXXV_ASSERT(bits == table && words == word_count && pages == count, "scan exactly the installed bitmap");
  return selected;
}
}

#define first_free_page scanned_page
#include "os.cc"
#undef first_free_page

using namespace toit;

static bool locked, commit_ok;
static unsigned commits, releases;
static uword expected_address;
static uword selected_word, observed_word, live_word;
static uint64 selected_before, observed_before, live_before, mask, live_mask;
static bool new_held, old_released;
static void* release_address;
static uword release_size;

static uint64 expected_word(uword index, uint64 initial) {
  if (new_held && index == selected_word) initial |= mask;
  if (old_released && index == live_word) initial &= ~live_mask;
  return initial;
}

static void check_bitmap_state() {
  CXXV_ASSERT(table[selected_word] == expected_word(selected_word, selected_before) &&
              table[observed_word] == expected_word(observed_word, observed_before) &&
              table[live_word] == expected_word(live_word, live_before),
              "the bitmap records exactly the grants held at this point");
}

void Locker::enter() {
  CXXV_ASSERT(!locked, "acquire the resource lock once");
  locked = true;
}
void Locker::leave() {
  CXXV_ASSERT(locked, "release the resource lock");
  locked = false;
}

bool OS::use_virtual_memory(void* address, uword bytes) {
  check_bitmap_state();
  ++commits;
  CXXV_ASSERT(locked && reinterpret_cast<uword>(address) == expected_address && bytes == count * TOIT_PAGE_SIZE,
              "commit the selected page range under the lock");
  return commit_ok;
}
void OS::unuse_virtual_memory(void* address, uword bytes) {
  check_bitmap_state();
  ++releases;
  CXXV_ASSERT(locked && address == release_address && bytes == release_size,
              "decommit only the released grant under the lock");
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  word_count = nondet_ulong();
  CXXV_ASSUME(word_count > 0 && word_count <= UINTPTR_MAX / (64 * TOIT_PAGE_SIZE));
  toit_heap_size = word_count * 64 * TOIT_PAGE_SIZE;
  uword base = nondet_ulong();
  CXXV_ASSUME(base != 0 && base % TOIT_PAGE_SIZE == 0 && base <= UINTPTR_MAX - toit_heap_size);
  toit_heap_range = reinterpret_cast<void*>(base);
  table = static_cast<uint64*>(malloc(word_count * sizeof(*table)));
  CXXV_ASSUME(table != nullptr);
  toit_heap_bits = table;

  count = nondet_uint();
  CXXV_ASSUME(count >= 1 && count <= 64);
  selected_word = nondet_ulong();
  observed_word = nondet_ulong();
  CXXV_ASSUME(selected_word < word_count && observed_word < word_count);
  unsigned offset = nondet_uint();
  CXXV_ASSUME(offset <= 64 - count);
  mask = (UINT64_MAX >> (64 - count)) << offset;
  bool exhausted = nondet_bool();
  // Choose any still-live grant before the scan. Its pages must stay owned
  // through an unrelated successful claim, failure, and subsequent release.
  bool has_live = nondet_bool();
  live_word = nondet_ulong();
  unsigned live_pages = nondet_uint();
  unsigned live_offset = nondet_uint();
  CXXV_ASSUME(live_word < word_count && live_pages >= 1 && live_pages <= 64 &&
              live_offset <= 64 - live_pages);
  live_mask = (UINT64_MAX >> (64 - live_pages)) << live_offset;
  uword live_begin = base + (64 * live_word + live_offset) * TOIT_PAGE_SIZE;
  uword live_end = live_begin + live_pages * TOIT_PAGE_SIZE;
  table[live_word] = static_cast<uint64>(nondet_int64());
  table[observed_word] = static_cast<uint64>(nondet_int64());
  table[selected_word] = static_cast<uint64>(nondet_int64());
  if (has_live) table[live_word] |= live_mask;
  selected_before = table[selected_word];
  // This is the postcondition of first_free_page for a successful search.
  CXXV_ASSUME(exhausted || (selected_before & mask) == 0);
  observed_before = table[observed_word];
  live_before = table[live_word];
  selected = 64 * selected_word + offset;
  expected_address = base + selected * TOIT_PAGE_SIZE;
  if (exhausted) selected = 64 * word_count;
  commit_ok = nondet_bool();
  void* result = OS::allocate_pages(count * TOIT_PAGE_SIZE);
  CXXV_ASSERT(!locked && commits == (exhausted ? 0 : 1), "only a selected range requests an OS commit");
  if (exhausted || !commit_ok) {
    CXXV_ASSERT(result == nullptr, "propagate exhaustion and commit failure");
  } else {
    new_held = true;
    check_bitmap_state();
    CXXV_ASSERT(reinterpret_cast<uword>(result) == expected_address, "return the selected page boundary");
    if (has_live) {
      uword granted = reinterpret_cast<uword>(result);
      CXXV_ASSERT(granted + count * TOIT_PAGE_SIZE <= live_begin || live_end <= granted,
                  "a new byte range is disjoint from every still-live grant");
      CXXV_ASSERT((table[live_word] & live_mask) == live_mask,
                  "publishing a new grant preserves all pages of the live grant");
    }
    if (has_live && nondet_bool()) {
      // An older grant may be returned while the grant just made is live.
      old_released = true;
      release_address = reinterpret_cast<void*>(live_begin);
      release_size = live_pages * TOIT_PAGE_SIZE;
      OS::free_pages(release_address, release_size);
      CXXV_ASSERT(releases == 1 && !locked && (table[selected_word] & mask) == mask,
                  "releasing the older grant keeps the complete newer grant live");
    }
    new_held = false;
    release_address = result;
    release_size = count * TOIT_PAGE_SIZE;
    OS::free_pages(result, release_size);
  }
  check_bitmap_state();
  CXXV_ASSERT(!locked && releases == unsigned(!exhausted && commit_ok) + unsigned(old_released),
              "decommit exactly once for each released grant");
  CXXV_ASSERT(!has_live || (table[live_word] & live_mask) == (old_released ? 0 : live_mask),
              "the older grant stays allocated until its own release");
  free(table);
}
