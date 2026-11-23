// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "os.h"
#undef private
#include <limits.h>
#include <stdlib.h>

using namespace toit;

static uword expected_size, raw_base;
static bool bitmap_failure;
static uint64 bitmap_token;
static unsigned reservations, releases, bitmap_requests, environment_reads;
static char setting[2];
static long parsed;
static bool configured;

static char* read_setting(const char*) {
  ++environment_reads;
  return configured ? setting : nullptr;
}
static long parse_setting(const char*, char**, int) { return parsed; }
static void* allocate_bitmap(size_t words, size_t width) {
  ++bitmap_requests;
  CXXV_ASSERT(words == expected_size / (64 * TOIT_PAGE_SIZE) && width == sizeof(uint64),
              "request a zero-initialized word for every 64 heap pages");
  return bitmap_failure ? nullptr : &bitmap_token;
}

#define getenv read_setting
#define strtol parse_setting
#define calloc allocate_bitmap
#include "os.cc"
#undef calloc
#undef strtol
#undef getenv

static void check_unpublished() {
  CXXV_ASSERT(OS::single_range_.address == nullptr && OS::single_range_.size == 0 &&
              toit_heap_range == nullptr && toit_heap_size == 0 && toit_heap_bits == nullptr,
              "no heap or bitmap is published during partial initialization");
}
void* OS::grab_virtual_memory(void* hint, uword bytes) {
  check_unpublished();
  ++reservations;
  CXXV_ASSERT(hint == nullptr && bytes == expected_size + TOIT_PAGE_SIZE && bitmap_requests == 0,
              "reserve the heap with room for alignment before requesting the bitmap");
  return reinterpret_cast<void*>(raw_base);
}
void OS::ungrab_virtual_memory(void* base, uword bytes) {
  check_unpublished();
  ++releases;
  CXXV_ASSERT(raw_base != 0 && reinterpret_cast<uword>(base) == raw_base &&
              bytes == expected_size + TOIT_PAGE_SIZE && bitmap_failure, "return the whole original reservation");
}
void toit::fail(const char*, ...) {
  check_unpublished();
  CXXV_ASSERT(reservations == 1 && (raw_base == 0 ? releases == 0 && bitmap_requests == 0 :
              bitmap_failure && bitmap_requests == 1 && releases == 1), "allocation failure leaves no owned reservation");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  configured = nondet_bool();
  setting[0] = nondet_uchar();
  parsed = nondet_long();
  CXXV_ASSUME(parsed >= 0);
  uword cap_gb = WORD_BIT_SIZE == 32 ? 1 : 1024;
  bool valid = configured && setting[0] >= '0' && setting[0] <= '9' && parsed != 0 && parsed != LONG_MAX;
  expected_size = valid ? Utils::min(static_cast<uword>(parsed), cap_gb) * GB : MAX_HEAP;
  raw_base = nondet_ulong();
  uword last_offset = expected_size + TOIT_PAGE_SIZE - 1;
  CXXV_ASSUME(raw_base <= UINTPTR_MAX - last_offset);
  bitmap_failure = nondet_bool();

  auto range = OS::get_heap_memory_range();
  uword aligned = reinterpret_cast<uword>(range.address);
  CXXV_ASSERT(raw_base != 0 && !bitmap_failure && aligned >= raw_base && aligned - raw_base < TOIT_PAGE_SIZE &&
              aligned % TOIT_PAGE_SIZE == 0 && range.size == expected_size &&
              range.size - 1 <= UINTPTR_MAX - aligned && aligned + (range.size - 1) <= raw_base + last_offset,
              "publish an aligned heap fully contained in the reservation");
  CXXV_ASSERT(toit_heap_bits == &bitmap_token && toit_heap_range == range.address && toit_heap_size == range.size,
              "publish the matching page table and allocator state");
  auto again = OS::get_heap_memory_range();
  CXXV_ASSERT(again.address == range.address && again.size == range.size && reservations == 1 &&
              bitmap_requests == 1 && environment_reads == 1 && releases == 0, "reuse the initialized heap on a second call");
}
