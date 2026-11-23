// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#undef TOIT_FREERTOS
#include "mutex.h"
#define TOIT_FREERTOS
#include "os.h"
#include "os_page_extent.h"
#include "cmpctmalloc.h"
#include "stats_type.inc"

using namespace toit;

static bool running, suspended;
static unsigned registrations;
static cmpct_heap_t *registration_result, *competitor;
static uword low, high;
static cmpct_heap_t* heap;
static multi_heap_info_t reported;
static unsigned queries;

void cmpct_get_info_impl(cmpct_heap_t* queried_heap, multi_heap_info_t* info) {
  CXXV_ASSERT(heap != nullptr && queried_heap == heap, "query the initialized allocator");
  ++queries;
  *info = reported;
}
#include "port_stats.inc"

// The linker supplies addresses. The VM never reads the bytes at either symbol.
static char *linker_low, *linker_high;
#define end_ap_data (*linker_low)
#define start_up_buffer (*linker_high)
#define taskSCHEDULER_NOT_STARTED 0
static int xTaskGetSchedulerState() { return running; }
static void vTaskSuspendAll() {
  CXXV_ASSERT(running && !suspended, "suspend the running scheduler once");
  // A different task may have finished registration before suspension.
  if (!heap) heap = competitor;
  suspended = true;
}
static void xTaskResumeAll() {
  CXXV_ASSERT(suspended, "resume only after suspension");
  suspended = false;
}
cmpct_heap_t* cmpct_register_impl(void* start, size_t bytes) {
  CXXV_ASSERT(!heap && (!running || suspended), "register once under scheduler exclusion or during boot");
  CXXV_ASSERT(reinterpret_cast<uword>(start) == low && bytes > 0 &&
              static_cast<uint64_t>(low) + bytes == high, "register the exact ordered linker interval");
  ++registrations;
  return registration_result;
}
#include "port_init.inc"

enum Operation { MALLOC, REALLOC, FREE, MEMALIGN };
static Operation operation;
static void *argument, *result;
static size_t size, alignment;
static unsigned calls;

static void observe(Operation call, cmpct_heap_t* handle) {
  ++calls;
  CXXV_ASSERT(operation == call && handle && handle == heap, "delegate only to the published allocator");
}
void* cmpct_malloc_impl(cmpct_heap_t* handle, size_t bytes) {
  observe(MALLOC, handle);
  CXXV_ASSERT(bytes == size, "forward malloc size");
  return result;
}
void* cmpct_realloc_impl(cmpct_heap_t* handle, void* ptr, size_t bytes) {
  observe(REALLOC, handle);
  CXXV_ASSERT(bytes == size && ptr == argument, "forward realloc arguments");
  return result;
}
void* cmpct_aligned_alloc_impl(cmpct_heap_t* handle, size_t bytes, size_t align) {
  observe(MEMALIGN, handle);
  CXXV_ASSERT(bytes == size && align == alignment, "forward memalign arguments");
  return result;
}
void cmpct_free_impl(cmpct_heap_t* handle, void* ptr) {
  observe(FREE, handle);
  CXXV_ASSERT(ptr == argument && ptr != nullptr, "forward the original non-null pointer");
}
#include "port_alloc.inc"

namespace toit {
#define TOIT_CMPCTMALLOC 1
#include "heap_range.inc"
#undef start_up_buffer
#undef end_ap_data
}

int main() {
  static_assert(WORD_BIT_SIZE == 32, "EC618 address width");
  low = nondet_uint();
  high = nondet_uint();
  CXXV_ASSUME(low > 0);
  linker_low = reinterpret_cast<char*>(low);
  linker_high = reinterpret_cast<char*>(high);

  running = nondet_bool();
  bool initialize = nondet_bool();
  if (high > low) competitor = reinterpret_cast<cmpct_heap_t*>(static_cast<uword>(nondet_uint()));
  cmpct_heap_t* expected = nullptr;
  unsigned expected_registrations = 0;
  if (initialize) {
    for (unsigned attempt = 0; attempt < 2; ++attempt) {
      registration_result = reinterpret_cast<cmpct_heap_t*>(static_cast<uword>(nondet_uint()));
      if (!expected && running) expected = competitor;
      if (!expected && high > low) {
        ++expected_registrations;
        expected = registration_result;
      }
      int ready = ensure_heap_initialized();
      CXXV_ASSERT(heap == expected && ready == (expected != nullptr) && !suspended &&
                  registrations == expected_registrations,
                  "publish successful registration, allow retry on failure, and preserve an existing heap");
    }
  }
  OS::HeapMemoryRange range = OS::get_heap_memory_range();
  const uint64_t base = reinterpret_cast<uword>(range.address);
  const uint64_t end = base + range.size;
  const uint64_t first = ((uint64_t(low) + TOIT_PAGE_SIZE - 1) / TOIT_PAGE_SIZE) * TOIT_PAGE_SIZE;
  const uint64_t limit = (uint64_t(high) / TOIT_PAGE_SIZE) * TOIT_PAGE_SIZE;
  CXXV_ASSERT(queries == 0, "GC range discovery is independent of allocator statistics");
  if (first < limit) {
    CXXV_ASSERT(base == first && end == limit, "cover exactly the whole linker-arena pages");
  } else {
    CXXV_ASSERT(range.size == 0, "an arena without a whole page has an empty GC range");
  }
  const uword candidate = nondet_uint();
  const uword bytes = nondet_uint();
  if (bytes && candidate % TOIT_PAGE_SIZE == 0 && bytes % TOIT_PAGE_SIZE == 0) {
    const uint64_t candidate_end = uint64_t(candidate) + bytes;
    CXXV_ASSERT((low <= candidate && candidate_end <= high) == (base <= candidate && candidate_end <= end),
                "contain exactly the aligned whole-page chunks that fit the registered interval");
  }

  // Diagnostic callers still use the board's statistics wrapper.
  reported.lowest_address = reinterpret_cast<void*>(static_cast<uword>(nondet_uint()));
  reported.highest_address = reinterpret_cast<void*>(static_cast<uword>(nondet_uint()));
  heap_stats_t stats;
  vPortGetHeapStats(&stats);
  CXXV_ASSERT(queries == static_cast<unsigned>(expected != nullptr), "only query cmpctmalloc after initialization");
  CXXV_ASSERT(stats.lowest_address == (expected ? reported.lowest_address : nullptr) &&
              stats.highest_address == (expected ? reported.highest_address : nullptr),
              "forward the reported diagnostic bounds for an initialized heap");

  // Exercise a public allocator entry with the previous initialization outcome.
  operation = static_cast<Operation>(nondet_uint() % 4);
  argument = reinterpret_cast<void*>(static_cast<uword>(nondet_uint()));
  result = reinterpret_cast<void*>(static_cast<uword>(nondet_uint()));
  registration_result = reinterpret_cast<cmpct_heap_t*>(static_cast<uword>(nondet_uint()));
  size = nondet_uint();
  alignment = nondet_uint();
  void* returned = nullptr;
  switch (operation) {
    case MALLOC: returned = pvPortMallocEC(size, 0); break;
    case REALLOC: returned = pvPortReallocEC(argument, size, 0); break;
    case FREE: vPortFree(argument); break;
    case MEMALIGN: returned = pvPortMemalign(alignment, size); break;
  }
  if (operation != FREE || argument != nullptr) {
    if (!expected && running) expected = competitor;
    if (!expected && high > low) {
      ++expected_registrations;
      expected = registration_result;
    }
  }
  CXXV_ASSERT(heap == expected && registrations == expected_registrations && !suspended,
              "all four entries preserve the registration and scheduler state");
  CXXV_ASSERT(calls == static_cast<unsigned>(expected && (operation != FREE || argument)),
              "allocation failure and freeing null skip the allocator");
  CXXV_ASSERT(returned == (expected && operation != FREE ? result : nullptr),
              "return null on registration failure and propagate the allocator result");
}
