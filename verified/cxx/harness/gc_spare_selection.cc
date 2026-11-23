// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#undef TOIT_FREERTOS
#include "mutex.h"
#define TOIT_FREERTOS
#define private public
#include "third_party/dartino/gc_metadata.h"
#undef private

using namespace toit;
GcMetadata GcMetadata::singleton_;
extern Mutex spare_mutex;
static bool locked, page_failure, descriptor_failure;
static unsigned reservations, descriptors, releases;
static uword base, shared_address, candidate_address, released_address;
static uint8 kinds[3];

// Use the same descriptor storage for the placement constructor and the
// destructor, as the VM's nonthrowing allocator does.
static void* storage;
static bool reserve_descriptor() {
  ++descriptors;
  if (locked && descriptor_failure) return false;
  storage = malloc(sizeof(Chunk));
  CXXV_ASSUME(storage != nullptr);
  return true;
}
#undef _new
#define _new !reserve_descriptor() ? nullptr : new (storage)
#include "object_memory.inc"
#undef _new
void operator delete(void* p) noexcept { free(p); }

void Locker::enter() {
  CXXV_ASSERT(!locked && mutex() == &spare_mutex && ObjectMemory::spare_chunk_ != nullptr,
              "take the shared spare mutex with a published page");
  locked = true;
}
void Locker::leave() {
  CXXV_ASSERT(locked && ObjectMemory::spare_chunk_ != nullptr, "publish a live spare before unlocking");
  locked = false;
}
void* OS::allocate_pages(uword bytes) {
  CXXV_ASSERT(bytes == TOIT_PAGE_SIZE && ((!locked && !reservations) ||
              (locked && reservations == 1 && !ObjectMemory::spare_chunk_)),
              "attempt the optional replacement only while the shared spare is borrowed");
  ++reservations;
  if (locked && page_failure) return nullptr;
  return reinterpret_cast<void*>(locked ? candidate_address : shared_address);
}
bool OS::use_virtual_memory(void*, uword) { return true; }
void OS::free_pages(void* address, uword bytes) {
  CXXV_ASSERT(bytes == TOIT_PAGE_SIZE, "release a whole page");
  ++releases;
  released_address = reinterpret_cast<uword>(address);
  if (locked) {
    CXXV_ASSERT(!ObjectMemory::spare_chunk_ && kinds[(released_address - base) / TOIT_PAGE_SIZE] == UNKNOWN_SPACE_PAGE,
                "retire the unowned reservation under the lock");
  }
}
void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "valid reservations and metadata avoid fatal errors");
  abort();
}

int main() {
  base = nondet_uint();
  CXXV_ASSUME(base && base % TOIT_PAGE_SIZE == 0 && base <= UINTPTR_MAX - sizeof(kinds) * TOIT_PAGE_SIZE);
  unsigned shared = nondet_uint() % 3, candidate = nondet_uint() % 3;
  CXXV_ASSUME(shared != candidate);
  shared_address = base + shared * TOIT_PAGE_SIZE;
  candidate_address = base + candidate * TOIT_PAGE_SIZE;
  auto& meta = GcMetadata::singleton_;
  meta.lowest_address_ = base;
  meta.heap_extent_ = sizeof(kinds) * TOIT_PAGE_SIZE;
  meta.page_type_bytes_ = kinds;
  unsigned other = 3 - shared - candidate;
  kinds[other] = OLD_SPACE_PAGE;
  ObjectMemory::allocated_ = 0;
  ObjectMemory::spare_chunk_mutex_ = &spare_mutex;
  ObjectMemory::spare_chunk_ = ObjectMemory::allocate_chunk(nullptr, TOIT_PAGE_SIZE);
  page_failure = nondet_bool();
  descriptor_failure = nondet_bool();
  bool replace = !page_failure && !descriptor_failure && candidate < shared;
  uword retained = replace ? candidate_address : shared_address;
  {
    Locker locker(&spare_mutex);
    Chunk* chosen = ObjectMemory::take_spare_chunk(locker);
    CXXV_ASSERT(locked && !ObjectMemory::spare_chunk_ && chosen && chosen->start() == retained &&
                chosen->size() == TOIT_PAGE_SIZE && chosen->owner() == nullptr,
                "borrow the lower usable spare, keeping the original if allocation failed");
    CXXV_ASSERT(reservations == 2 && descriptors == 1u + !page_failure &&
                releases == static_cast<unsigned>(!page_failure) &&
                (page_failure || released_address == (replace ? shared_address : candidate_address)),
                "release exactly the unused page, including a failed descriptor reservation");
    CXXV_ASSERT(ObjectMemory::allocated() == TOIT_PAGE_SIZE && kinds[other] == OLD_SPACE_PAGE,
                "retain one page charge and preserve unrelated metadata");
    ObjectMemory::set_spare_chunk(locker, chosen);
  }
  CXXV_ASSERT(!locked && ObjectMemory::spare_chunk_->start() == retained, "published spare survives unlock");
  ObjectMemory::free_chunk(ObjectMemory::spare_chunk_);
  ObjectMemory::spare_chunk_ = nullptr;
  CXXV_ASSERT(releases == 1u + !page_failure && released_address == retained && ObjectMemory::allocated() == 0,
              "release the remaining page exactly once and restore the initial charge");
}
