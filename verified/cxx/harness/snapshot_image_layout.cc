// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "snapshot.cc"
#undef protected
#undef private

using namespace toit;

// Check any valid external cursor independently of the counts that produced it.
static void check_external_allocation() {
  ImageAllocator allocator;
  uword top = nondet_ulong();
  unsigned available = nondet_uint();
  CXXV_ASSUME(top != 0 && top % WORD_SIZE == 0 && available <= INT_MAX &&
              available % WORD_SIZE == 0 && top <= UINTPTR_MAX - available);
  allocator.external_top_ = reinterpret_cast<void*>(top);
  allocator.external_end_ = reinterpret_cast<void*>(top + available);
  int count = nondet_int();
  unsigned kind = nondet_uint() % 4;
  void* result;
  uint64 elements = static_cast<unsigned>(count);
  uint64 payload;
  switch (kind) {
    case 0:
      payload = elements;
      result = allocator.allocate_external_bytes(count);
      break;
    case 1:
      payload = elements * 2;
      result = allocator.allocate_external_uint16s(count);
      break;
    case 2:
      payload = elements * 4;
      result = allocator.allocate_external_int32s(count);
      break;
    default:
      payload = elements * WORD_SIZE;
      result = allocator.allocate_external_pointers(count);
      break;
  }
  if (count < 0 || payload > available) {
    CXXV_ASSERT(result == nullptr && reinterpret_cast<uword>(allocator.external_top_) == top,
                "reject unrepresentable or exhausted typed requests without consuming the image");
  } else {
    uint64 reserved = (payload + WORD_SIZE - 1) / WORD_SIZE * WORD_SIZE;
    uword next = reinterpret_cast<uword>(allocator.external_top_);
    CXXV_ASSERT(reinterpret_cast<uword>(result) == top && next == top + reserved &&
                next <= top + available, "each successful slice starts after earlier tables and ends before program blocks");
  }
}

int main() {
  check_external_allocation();
  static_assert(CXXV_WORD_BITS == WORD_BIT_SIZE, "target width");
  int blocks = nondet_int(), pointers = nondet_int(), ints = nondet_int(), bytes = nondet_int();
  ImageAllocator allocator;
  allocator.HeapAllocator::initialize(blocks, pointers, ints, bytes);
  int external = -1, total = -1;
  bool ok = allocator.image_sizes(&external, &total);
  if (blocks < 0 || pointers < 0 || ints < 0 || bytes < 0) {
    CXXV_ASSERT(!ok && total == -1 && external == -1, "reject negative counts without publishing a layout");
    return 0;
  }
  uint64 words = (sizeof(Program) + WORD_SIZE - 1) / WORD_SIZE;
  words += pointers;
  words += (static_cast<uint64>(ints) * 4 + WORD_SIZE - 1) / WORD_SIZE;
  words += (static_cast<uint64>(bytes) + WORD_SIZE - 1) / WORD_SIZE;
  uint64 pages = (words * WORD_SIZE + TOIT_PAGE_SIZE - 1) / TOIT_PAGE_SIZE;
  uint64 required = (pages + blocks) * TOIT_PAGE_SIZE;
  CXXV_ASSERT(ok == (required <= INT_MAX), "accept precisely representable complete layouts");
  if (ok) {
    CXXV_ASSERT(static_cast<uint64>(external) == pages * TOIT_PAGE_SIZE &&
                static_cast<uint64>(total) == required, "separate the page-rounded external section from all heap blocks");
  } else {
    CXXV_ASSERT(external == -1 && total == -1, "oversized layouts publish no partial sizes");
  }
}
