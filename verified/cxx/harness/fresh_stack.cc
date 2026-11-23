// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "objects_inline.h"
namespace toit {
template<> inline void Utils::fill_words<Object*>(Object**, uword, Object*);
}
#include "heap.cc"
#include "objects.cc"
#undef protected
#undef private

using namespace toit;

extern Program image;
static word length;
static word slot;
static uword saved;
static uword* storage;
static bool grant;
static unsigned requests, fills;

namespace toit {
template<> inline void Utils::fill_words<Object*>(Object** base, uword count, Object* value) {
  ++fills;
  CXXV_ASSERT(base == reinterpret_cast<Object**>(storage + Stack::HEADER_SIZE / WORD_SIZE) &&
              count == static_cast<uword>(length) && value == nullptr, "fill exactly the payload with tagged zero");
  // Apply the proved Utils::fill_words postcondition at the arbitrary slot.
  if (count > 0) base[slot] = value;
}
}  // namespace toit

// The reservation contract supplies disjoint, writable storage or fails.
// Seed one arbitrary payload word to check that header initialization
// distinguishes an explicit fill from an untouched reservation.
HeapObject* TwoSpaceHeap::allocate(uword size) {
  ++requests;
  CXXV_ASSERT(size == Stack::HEADER_SIZE + length * WORD_SIZE &&
              size <= ObjectHeap::max_allocation_size(), "reserve exactly the stack header, guards and slots");
  if (!grant) return nullptr;
  return HeapObject::from_address(reinterpret_cast<uword>(storage));
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  word cid = nondet_word();
  CXXV_ASSUME(0 <= cid && cid <= (Smi::MAX_SMI_VALUE >> HeapObject::CLASS_ID_OFFSET) && cid < INT32_MAX);
  uint16 classes[cid + 1];
  classes[cid] = nondet_ushort();
  CXXV_ASSUME(Program::class_tag_from_class_bits(classes[cid]) == STACK_TAG);
  image.class_bits = List<uint16>(classes, cid + 1);
  image.set_stack_class_id(Smi::from(cid));
  bool format2 = nondet_bool();
  uint8 code[] = {'T', 'B', 'C', static_cast<uint8>(format2 ? '2' : '1')};
  image.bytecodes = List<uint8>(code, 4);
  ObjectHeap heap(&image, nullptr, nullptr, nullptr, nullptr);
  length = nondet_word();
  CXXV_ASSUME(length >= 0 && length <= Stack::max_length());
  slot = nondet_word();
  CXXV_ASSUME(length == 0 || (slot >= 0 && slot < length));
  saved = nondet_ulong();
  uword words[Stack::HEADER_SIZE / WORD_SIZE + length];
  storage = words;
  grant = nondet_bool();
  if (length > 0) storage[Stack::HEADER_SIZE / WORD_SIZE + slot] = saved;
  Stack* result = heap.allocate_stack(length);
  CXXV_ASSERT(requests == 1 && (result != nullptr) == grant,
              "return allocation failure exactly when reservation fails");
  CXXV_ASSERT(fills == unsigned(grant && format2), "initialize all slots on every successful format-2 reservation");
  if (result != nullptr) {
    CXXV_ASSERT(result->_raw() == reinterpret_cast<uword>(storage), "return the tagged reservation");
    CXXV_ASSERT(result->has_class_tag(STACK_TAG), "install the stack type tag from the loaded table");
    CXXV_ASSERT(Smi::value(result->class_id()) == cid, "preserve the stack class id");
    CXXV_ASSERT(result->length() == length && result->top() == length && result->try_top() == length,
                "initialize length, top and legacy try top");
    CXXV_ASSERT(!result->pending_stack_check_method().is_valid() && !result->is_guard_zone_touched(),
                "clear the pending method and initialize every guard");
    CXXV_ASSERT(result->_array_address(0) == storage + Stack::HEADER_SIZE / WORD_SIZE &&
                result->_array_address(length) == storage + Stack::HEADER_SIZE / WORD_SIZE + length,
                "expose exactly the writable slot range including the empty range");
    if (length > 0) {
      word position = length - 1 - slot;
      Object** address = result->v2_slot_address(position);
      CXXV_ASSERT(address == reinterpret_cast<Object**>(storage + Stack::HEADER_SIZE / WORD_SIZE + slot),
                  "resolve each primitive argument position from the end of the slot array");
      CXXV_ASSERT(*result->_array_address(slot) == (format2 ? 0 : saved),
                  "provide initialized format-2 words and preserve legacy slots");
    }
  }
  exit(0);  // The check ends before heap teardown.
}
