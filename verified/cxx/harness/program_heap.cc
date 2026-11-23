// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "interpreter_v2.cc"
#undef protected
#undef private

using namespace toit;

extern Program image;
extern Process subject;
extern V2MethodTable methods;

int main() {
  static_assert(sizeof(uword) * 8 == CXXV_WORD_BITS, "target word width");
  uint16 pages = nondet_ushort();
  image.header_.size_in_pages_ = pages;
  CXXV_ASSERT(image.size_no_assets() == static_cast<word>(pages) * 4096,
              "the packed flash header supplies the byte extent");

  toit_v2_program tables;
  v2_program_tables(&image, &methods, nullptr, &tables);
  CXXV_ASSERT(tables.program_heap_start == reinterpret_cast<uword>(&image), "the Rust tables point to the same image");
  CXXV_ASSERT(tables.program_heap_size == static_cast<uword>(pages) * 4096, "the Rust tables receive the header extent");

  uword start = nondet_ulong();
  uword size = nondet_ulong();
  uword address = nondet_ulong();
  subject.program_ = reinterpret_cast<Program*>(start);
  subject.program_heap_size_ = size;
  bool inside = subject.on_program_heap(reinterpret_cast<HeapObject*>(address));

  // Compute the exclusive end in a type that represents one past UINTPTR_MAX.
#if CXXV_WORD_BITS == 32
  typedef uint64 Wide;
#else
  typedef unsigned __int128 Wide;
#endif
  Wide end = static_cast<Wide>(start) + size;
  CXXV_ASSERT(inside == (start <= address && static_cast<Wide>(address) < end),
              "membership in the mathematical half-open interval");
  if (end <= static_cast<Wide>(UINTPTR_MAX) + 1) {
    CXXV_ASSERT(inside == (address - start < size), "agreement with the unsigned VM range test for mapped images");
  }
}
