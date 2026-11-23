// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "heap.cc"
#include "objects.cc"
#undef protected
#undef private

using namespace toit;

extern Program image;
static word length;
static uint8* reservation;
static unsigned requests;

HeapObject* TwoSpaceHeap::allocate(uword size) {
  ++requests;
  uword minimum = String::INTERNAL_HEADER_SIZE + length + 1;
  CXXV_ASSERT(size >= minimum && size - minimum < WORD_SIZE && size % WORD_SIZE == 0,
              "reserve exactly the aligned header, payload and terminator");
  CXXV_ASSERT(size <= ObjectHeap::max_allocation_size(), "fit one process heap block");
  if (nondet_bool()) return nullptr;
  reservation = static_cast<uint8*>(malloc(size));
  if (reservation == nullptr) return nullptr;
  return HeapObject::from_address(reinterpret_cast<uword>(reservation));
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uint16 classes[1024];
  unsigned cid = nondet_uint();
  CXXV_ASSUME(cid < 1024);
  classes[cid] = nondet_ushort();
  CXXV_ASSUME(Program::class_tag_from_class_bits(classes[cid]) == STRING_TAG);
  image.class_bits = List<uint16>(classes, 1024);
  image.set_string_class_id(Smi::from(cid));
  ObjectHeap* heap = new ObjectHeap(&image, nullptr, nullptr, nullptr, nullptr);
  CXXV_ASSUME(heap != nullptr);

  length = nondet_word();
  CXXV_ASSUME(0 <= length && length <= String::max_internal_size_in_process());
  String* result = heap->allocate_internal_string(length);
  CXXV_ASSERT(requests == 1 && (result == nullptr) == (reservation == nullptr),
              "propagate the outcome of a single raw reservation");
  if (result == nullptr) return 0;
  CXXV_ASSERT(result == HeapObject::from_address(reinterpret_cast<uword>(reservation)) &&
              result->class_id() == Smi::from(cid) && result->has_class_tag(STRING_TAG),
              "initialize the reserved object with the builtin string class");
  CXXV_ASSERT(result->content_on_heap() && result->length() == length &&
              result->_raw_hash_code() == String::NO_HASH_CODE, "initialize internal length and uncached hash");
  String::Bytes bytes(result);
  CXXV_ASSERT(bytes.address() == reservation + String::INTERNAL_HEADER_SIZE && bytes.length() == length &&
              bytes.address()[length] == 0, "expose the payload with a trailing NUL inside the reservation");
}
