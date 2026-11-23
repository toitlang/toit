// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "float_payload.h"
#define private public
#define protected public
#include "heap.cc"
#include "objects.cc"
#undef protected
#undef private

using namespace toit;

extern Program loaded_program;

static HeapObject* reserved;
static unsigned reservations;

// Boundary of this proof: the space allocator returns fresh aligned storage
// of exactly the requested size, or reports exhaustion.
HeapObject* TwoSpaceHeap::allocate(uword size) {
  ++reservations;
  CXXV_ASSERT(size == sizeof(word) + sizeof(int64), "exact boxed number allocation size");
  if (nondet_bool()) return nullptr;
  void* storage = malloc(size);
  if (storage == nullptr) return nullptr;
  reserved = HeapObject::from_address(reinterpret_cast<uword>(storage));
  return reserved;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uint16 classes[1024];
  unsigned cid = nondet_uint();
  CXXV_ASSUME(cid < 1024);
  bool floating = nondet_bool();
  TypeTag tag = floating ? DOUBLE_TAG : LARGE_INTEGER_TAG;
  classes[cid] = nondet_ushort();
  CXXV_ASSUME(Program::class_tag_from_class_bits(classes[cid]) == tag);
  loaded_program.class_bits = List<uint16>(classes, 1024);
  loaded_program._builtin_class_ids[floating ? Program::double_class_id_INDEX : Program::large_integer_class_id_INDEX] = Smi::from(cid);
  ObjectHeap* heap = new ObjectHeap(&loaded_program, nullptr, nullptr, nullptr, nullptr);
  CXXV_ASSUME(heap != nullptr);
  int64 value = nondet_int64();
  HeapObject* result;
  if (floating) {
    result = heap->allocate_double(bit_cast<double>(value));
  } else {
    result = heap->allocate_large_integer(value);
  }
  CXXV_ASSERT(reservations == 1 && result == reserved, "request one reservation and return its result");
  if (result != nullptr) {
    CXXV_ASSERT(result->class_id() == Smi::from(cid) && result->has_class_tag(tag), "set builtin class and tag");
    int64 payload = floating ? bit_cast<int64>(Double::cast(result)->value()) : LargeInteger::cast(result)->value();
    CXXV_ASSERT(floating ? same_double_payload(payload, value) : payload == value, "preserve the boxed numeric value");
  }
}
