// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/gc_metadata.h"
#undef private

using namespace toit;

static bool descriptor_failure;
#undef _new
#define _new descriptor_failure ? nullptr : new (std::nothrow)
#include "third_party/dartino/object_memory.cc"
#undef _new

GcMetadata GcMetadata::singleton_;
extern Mutex spare_mutex;
static Chunk* published;
static bool metadata_live, mutex_live, page_failure, mutex_failure, duplicate, early_teardown;
static unsigned setups, teardowns, allocations, mutex_requests, disposals;
static uint8 page_kind;
static constexpr uword base = 16 * TOIT_PAGE_SIZE;

void GcMetadata::set_up() {
  CXXV_ASSERT(!metadata_live && !duplicate && !early_teardown, "initialize metadata once before allocating the spare");
  ++setups;
  metadata_live = true;
  singleton_.lowest_address_ = base;
  singleton_.heap_extent_ = TOIT_PAGE_SIZE;
  singleton_.page_type_bytes_ = &page_kind;
  singleton_.metadata_ = reinterpret_cast<uint8*>(base);
  singleton_.metadata_size_ = TOIT_PAGE_SIZE;
  singleton_.mark_bits_bias_ = base - base / (8 * WORD_SIZE);
  singleton_.cumulative_mark_bits_bias_ = base + TOIT_PAGE_SIZE / 2 - base / 32;
}
void GcMetadata::tear_down() {
  CXXV_ASSERT(metadata_live && !mutex_live && ObjectMemory::allocated() == 0 &&
              !ObjectMemory::spare_chunk_ && !ObjectMemory::spare_chunk_mutex(),
              "retire the spare and mutex before releasing metadata");
  ++teardowns;
  metadata_live = false;
}
void* OS::allocate_pages(uword size) {
  CXXV_ASSERT(metadata_live && ObjectMemory::allocated() == 0 && size == TOIT_PAGE_SIZE, "reserve one spare page");
  ++allocations;
  return page_failure ? nullptr : reinterpret_cast<void*>(base);
}
void OS::free_pages(void* address, uword bytes) {
  CXXV_ASSERT(metadata_live && reinterpret_cast<uword>(address) == base && bytes == TOIT_PAGE_SIZE,
              "return the page while metadata is live");
}
bool OS::use_virtual_memory(void*, uword) { return true; }
Mutex* OS::allocate_mutex(int level, const char*) {
  CXXV_ASSERT(metadata_live && ObjectMemory::allocated() == TOIT_PAGE_SIZE && level == 7 &&
              !mutex_live && !ObjectMemory::spare_chunk_, "request the mutex before publishing the spare");
  ++mutex_requests;
  mutex_live = !mutex_failure;
  return mutex_live ? &spare_mutex : nullptr;
}
void OS::dispose(Mutex* mutex) {
  CXXV_ASSERT(metadata_live && mutex_live && mutex == &spare_mutex, "dispose the live spare mutex once");
  ++disposals;
  mutex_live = false;
}
void toit::fail(const char*, ...) {
  if (early_teardown) {
    CXXV_ASSERT(!metadata_live && !setups && !disposals, "reject teardown before initialization");
  } else if (duplicate) {
    CXXV_ASSERT(metadata_live && mutex_live && setups == 1 && allocations == 1 && ObjectMemory::spare_chunk_ == published &&
                ObjectMemory::spare_chunk_mutex() == &spare_mutex &&
                ObjectMemory::allocated() == TOIT_PAGE_SIZE, "duplicate setup preserves the live spare and charge");
    // The fatal duplicate call retains the original owner's descriptor.
    // Release its storage in the observer for ESBMC's terminal leak check.
    delete published;
  } else {
    CXXV_ASSERT((page_failure || descriptor_failure || mutex_failure) && !metadata_live && !mutex_live &&
                setups == 1 && teardowns == 1 && allocations == 1 && mutex_requests == (!page_failure && !descriptor_failure) &&
                ObjectMemory::allocated() == 0, "failure cleans up every acquired resource before stopping");
  }
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  early_teardown = nondet_bool();
  if (early_teardown) {
    ObjectMemory::tear_down();
    CXXV_ASSERT(false, "unmatched teardown cannot return");
  }
  page_failure = nondet_bool();
  descriptor_failure = nondet_bool();
  mutex_failure = nondet_bool();
  ObjectMemory::set_up();
  CXXV_ASSERT(!page_failure && !descriptor_failure && !mutex_failure && setups == 1 && mutex_requests == 1 &&
              ObjectMemory::spare_chunk_mutex() == &spare_mutex && ObjectMemory::spare_chunk_->owner() == nullptr &&
              ObjectMemory::spare_chunk_->size() == TOIT_PAGE_SIZE, "publish both resources only after successful setup");
  published = ObjectMemory::spare_chunk_;
  duplicate = nondet_bool();
  if (duplicate) {
    ObjectMemory::set_up();
    CXXV_ASSERT(false, "duplicate setup cannot return");
  }
  ObjectMemory::tear_down();
  CXXV_ASSERT(disposals == 1 && teardowns == 1 && !metadata_live && !mutex_live, "normal shutdown balances startup");
}
