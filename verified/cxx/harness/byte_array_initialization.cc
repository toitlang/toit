// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
static void* zero_payload(void*, int, size_t);
#define private public
#define protected public
#define memset zero_payload
#include "objects.h"
#undef memset
#include "heap.cc"
#include "objects.cc"
#undef protected
#undef private

using namespace toit;
extern Program image;
static bool external, fail_reservation;
static word length;
static uword probe;
static uint8* storage;
static uint8* payload;
static unsigned requests, fills;

// Model libc at one arbitrary payload position. Check the complete write
// interval independently, including the zero-length call.
static void* zero_payload(void* p, int value, size_t n) {
  CXXV_ASSERT(p == payload && value == 0 && n == static_cast<uword>(length) && !fills,
              "clear exactly the requested bytes at the start of the payload");
  ++fills;
  if (probe < n) payload[probe] = 0;
  return p;
}

HeapObject* TwoSpaceHeap::allocate(uword size) {
  ++requests;
  if (external) {
    CXXV_ASSERT(size == ByteArray::EXTERNAL_SIZE, "reserve the external descriptor");
  } else {
    uword minimum = ByteArray::HEADER_SIZE + static_cast<uword>(length);
    CXXV_ASSERT(size >= minimum && size - minimum < WORD_SIZE && size % WORD_SIZE == 0 &&
                size <= ObjectHeap::max_allocation_size(), "reserve the aligned in-heap header and payload");
  }
  if (fail_reservation) return nullptr;
  storage = static_cast<uint8*>(malloc(size));
  CXXV_ASSUME(storage != nullptr);
  if (!external) {
    payload = storage + ByteArray::HEADER_SIZE;
    if (probe < static_cast<uword>(length)) payload[probe] = 123;
  }
  return HeapObject::from_address(reinterpret_cast<uword>(storage));
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uint16 classes[] = {Program::compute_class_bits(BYTE_ARRAY_TAG, 0)};
  image.class_bits = List<uint16>(classes, 1);
  image.set_byte_array_class_id(Smi::from(0));
  ObjectHeap heap(&image, nullptr, nullptr, nullptr, nullptr);
  external = nondet_bool();
  bool clear = nondet_bool();
  fail_reservation = nondet_bool();
  length = nondet_word();
  probe = nondet_ulong();
  if (external) {
    CXXV_ASSUME(length >= 0);
    payload = static_cast<uint8*>(malloc(length == 0 ? 1 : length));
    CXXV_ASSUME(payload != nullptr);
    if (probe < static_cast<uword>(length)) payload[probe] = 123;
  }
  ByteArray* result = external ? heap.allocate_external_byte_array(length, payload, false, clear)
                               : heap.allocate_internal_byte_array(length);
  bool valid = external || (length >= 0 && length <= ByteArray::max_internal_size_in_process());
  bool success = valid && !fail_reservation;
  bool cleared = success && (!external || clear);
  CXXV_ASSERT(requests == unsigned(valid) && (result != nullptr) == success && fills == unsigned(cleared),
              "reject invalid in-heap lengths and write only after obtaining the requested reservation");
  if (success) {
    ByteArray::Bytes view(result);
    CXXV_ASSERT(result->_raw() == reinterpret_cast<uword>(storage) && result->class_id() == Smi::from(0) &&
                result->class_tag() == BYTE_ARRAY_TAG && !result->has_active_finalizer() &&
                result->has_external_address() == external && view.address() == payload && view.length() == length,
                "expose the initialized representation, payload and logical length");
  }
  if ((success || external) && probe < static_cast<uword>(length)) {
    CXXV_ASSERT(payload[probe] == (cleared ? 0 : 123), "each payload byte has the requested initialization");
  }
  if (external) free(payload);
  if (storage) free(storage);
  exit(0);  // The modeled process heap outlives the check.
}
