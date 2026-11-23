// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#undef TOIT_FREERTOS
#include "mutex.h"
#define TOIT_FREERTOS
#ifdef CXXV_ESP32
#define TOIT_ESP32
#include "capabilities.inc"
#endif
#define private public
#include "os.h"
#undef private
#include "utils.h"
#include "heap_report.h"

using namespace toit;

static word initial_tag, tag, expected_page_tag;
static uword page_bytes, metadata_bytes;
static void *page_result, *metadata_result;
static unsigned page_calls, metadata_calls, page_frees, metadata_frees;
static bool releasing_metadata;
#ifdef CXXV_ESP32
static bool heap_external, metadata_external;
void heap_caps_set_option(int option, void* value) {
  CXXV_ASSERT(option == MALLOC_OPTION_THREAD_TAG, "set the calling thread's allocation tag");
  tag = reinterpret_cast<word>(value);
}
static void* heap_caps_get_option(int option) {
  CXXV_ASSERT(option == MALLOC_OPTION_THREAD_TAG, "read the calling thread's allocation tag");
  return reinterpret_cast<void*>(tag);
}
#else
// The EC618 table proof permits dropping a new tag when all slots are
// occupied. Clearing a tag and replacing an existing entry need no free slot.
static bool current_task, free_tag_slot;
static void vPortSetHeapTag(void* value) {
  if (current_task && (tag != 0 || value == nullptr || free_tag_slot)) {
    tag = reinterpret_cast<word>(value);
  }
}
static void* vPortGetHeapTag() { return reinterpret_cast<void*>(tag); }
#endif

static void* checked_aligned_alloc(size_t alignment, size_t bytes) {
  ++page_calls;
  CXXV_ASSERT(alignment == TOIT_PAGE_SIZE && bytes == page_bytes &&
              tag == expected_page_tag,
              "request the page-rounded extent under the available accounting tag");
  return page_result;
}
static void* checked_malloc(size_t bytes) {
  ++metadata_calls;
  CXXV_ASSERT(bytes == metadata_bytes && tag == initial_tag, "reserve the exact metadata extent under the caller's tag");
  return metadata_result;
}
static void checked_free(void* address) {
  if (releasing_metadata) {
    ++metadata_frees;
    CXXV_ASSERT(address == metadata_result, "release the original metadata pointer");
  } else {
    ++page_frees;
    CXXV_ASSERT(address == page_result, "release the original page pointer");
  }
}

#ifdef CXXV_ESP32
static int expected_caps(bool external) {
  return MALLOC_CAP_8BIT | (external ? MALLOC_CAP_SPIRAM : MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA);
}
static void* heap_caps_aligned_alloc(size_t alignment, size_t bytes, int caps) {
  CXXV_ASSERT(caps == expected_caps(heap_external), "select page capabilities using the heap RAM setting");
  return checked_aligned_alloc(alignment, bytes);
}
static void* heap_caps_malloc(size_t bytes, int caps) {
  CXXV_ASSERT(caps == expected_caps(metadata_external), "select metadata capabilities using the metadata RAM setting");
  return checked_malloc(bytes);
}
static void heap_caps_free(void* address) {
  CXXV_ASSERT(!releasing_metadata, "heap_caps_free releases the heap pages");
  checked_free(address);
}
#endif
static void checked_libc_free(void* address) {
#ifdef CXXV_ESP32
  CXXV_ASSERT(releasing_metadata, "the ESP32 libc release takes the metadata allocation");
#endif
  checked_free(address);
}

namespace toit {
#define aligned_alloc checked_aligned_alloc
#define malloc checked_malloc
#define free checked_libc_free
#include "page_backend.inc"
#undef free
#undef malloc
#undef aligned_alloc
}

int main() {
  static_assert(WORD_BIT_SIZE == 32 && TOIT_PAGE_SIZE == 4096, "embedded layout");
  expected_page_tag = ITERATE_CUSTOM_TAGS + TOIT_HEAP_MALLOC_TAG;
  initial_tag = tag = nondet_word();
#ifndef CXXV_ESP32
  current_task = nondet_bool();
  free_tag_slot = nondet_bool();
  CXXV_ASSUME(current_task || initial_tag == 0);
  if (!current_task || (!initial_tag && !free_tag_slot)) expected_page_tag = 0;
#endif
#ifdef CXXV_ESP32
  OS::use_spiram_for_heap_ = heap_external = nondet_bool();
  OS::use_spiram_for_metadata_ = metadata_external = nondet_bool();
#endif
  uword bytes = nondet_uint();
  CXXV_ASSUME(bytes > 0 && bytes <= UINTPTR_MAX - (TOIT_PAGE_SIZE - 1));
  page_bytes = (bytes / TOIT_PAGE_SIZE + (bytes % TOIT_PAGE_SIZE != 0)) * TOIT_PAGE_SIZE;
  page_result = reinterpret_cast<void*>(static_cast<uword>(nondet_uint()));
  CXXV_ASSUME(reinterpret_cast<uword>(page_result) % TOIT_PAGE_SIZE == 0);
  void* pages = OS::allocate_pages(bytes);
  CXXV_ASSERT(page_calls == 1 && tag == initial_tag && pages == page_result,
              "restore the caller's tag and propagate page allocation success or failure");
  if (pages) OS::free_pages(pages, page_bytes);

  metadata_bytes = nondet_uint();
  metadata_result = reinterpret_cast<void*>(static_cast<uword>(nondet_uint()));
  void* hint = reinterpret_cast<void*>(static_cast<uword>(nondet_uint()));
  void* metadata = OS::grab_virtual_memory(hint, metadata_bytes);
  CXXV_ASSERT(metadata_calls == 1 && metadata == metadata_result, "propagate the metadata allocator result");
  if (metadata) {
    CXXV_ASSERT(OS::use_virtual_memory(metadata, metadata_bytes), "using embedded metadata succeeds");
    OS::unuse_virtual_memory(metadata, metadata_bytes);
    releasing_metadata = true;
    OS::ungrab_virtual_memory(metadata, metadata_bytes);
  }
  CXXV_ASSERT(tag == initial_tag && page_calls == 1 && metadata_calls == 1 &&
              page_frees == (pages != nullptr) && metadata_frees == (metadata != nullptr),
              "return each allocation exactly once and preserve the caller's tag");
}
