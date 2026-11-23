// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "heap.cc"
#undef private
namespace toit {
#include "byte_array_neuter.inc"
}

using namespace toit;
extern Process owner;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  word length = nondet_word();
  uword current = nondet_ulong();
  CXXV_ASSUME(length >= 0 && static_cast<uword>(length) <= current);
  auto* heap = owner.object_heap();
  heap->external_memory_.store(current);
  uint64 lifetime = static_cast<uint64>(nondet_int64());
  heap->total_external_memory_.store(lifetime);
  uword words[ByteArray::EXTERNAL_SIZE / WORD_SIZE];
  uword class_bits = nondet_uint() & 0xffffu;
  words[0] = 2 * (BYTE_ARRAY_TAG | (class_bits << HeapObject::CLASS_ID_OFFSET));
  uint8 payload = nondet_uchar();
  uint8 before = payload;
  auto* array = static_cast<ByteArray*>(HeapObject::from_address(reinterpret_cast<uword>(words)));
  array->_initialize_external_memory(length, &payload, false);
  array->set_has_active_finalizer();
  uword header = words[0];
  uint8* detached = array->neuter(&owner);
  CXXV_ASSERT(detached == &payload && payload == before && array->as_external() == nullptr && array->_external_length() == 0,
              "return the original external storage intact and clear the sender's pointer and length");
  CXXV_ASSERT(words[0] == header && array->external_tag() == RawByteTag, "preserve object identity and raw external representation");
  CXXV_ASSERT(heap->external_memory() == current - static_cast<uword>(length) && heap->total_external_memory_.load() == lifetime,
              "refund exactly the detached length from current external memory and preserve lifetime allocation accounting");
  array->clear_has_active_finalizer();
  CXXV_ASSERT(!array->has_active_finalizer() && words[0] == (header & ~(uword{2} << HeapObject::FINALIZER_BIT_OFFSET)) &&
              array->as_external() == nullptr && array->_external_length() == 0,
              "clearing the detached array's finalizer changes only its header flag");
}
