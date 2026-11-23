// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "objects_inline.h"
static unsigned old_requests;
namespace toit { static void checked_array_init(Array*, word, Object*); }
#include "process_array_heap.inc"
#include "objects.cc"
#include "process_array_spaces.inc"
#undef protected
#undef private

using namespace toit;

extern Program image;
static ObjectHeap* process_heap;
static HeapObject* reserved;
static uword young_address;
static unsigned young_requests;
static uint8 card;
GcMetadata GcMetadata::singleton_;
static uword old_address;
static word array_witness;
static uword reserved_bytes;

// ffi/array_init.render proves that the initializer writes the length and
// every slot, leaving the class header and other storage alone. Materialize
// its postcondition at the arbitrary slot the caller will observe.
void toit::checked_array_init(Array* array, word count, Object* value) {
  CXXV_ASSERT(array != nullptr && array == reserved, "initialize the fresh reservation");
  CXXV_ASSERT(count >= 0 && count <= MAX_OBJECT_WORDS &&
              (LAYOUT_ARRAY_ELEMENTS_WORD + static_cast<uword>(count)) * WORD_SIZE == reserved_bytes,
              "supply the initializer's length word and all element slots");
  CXXV_ASSERT(!old_requests || card == GcMetadata::NEW_SPACE_POINTERS,
              "the old array is remembered before any filler store");
  auto raw = reinterpret_cast<uword*>(array->_raw());
  raw[LAYOUT_ARRAY_LENGTH_WORD] = count;
  if (array_witness >= 0 && array_witness < count)
    reinterpret_cast<Object**>(raw)[LAYOUT_ARRAY_ELEMENTS_WORD + array_witness] = value;
}

// The per-space reservation contracts supply the storage. Run the native
// two-space dispatch, accounting and card mark together with the constructor.
uword SemiSpace::allocate(uword size) {
  ++young_requests;
  CXXV_ASSERT(this == process_heap->two_space_heap_.new_space() && size == reserved_bytes &&
              size <= ObjectHeap::max_allocation_size(), "request the exact extent in the process semispace");
  return young_address;
}

uword OldSpace::allocate(uword size) {
  ++old_requests;
  CXXV_ASSERT(this == process_heap->two_space_heap_.old_space() && size == reserved_bytes,
              "retry the exact array extent in old space");
  return old_address;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  word cid = nondet_word();
  CXXV_ASSUME(0 <= cid && cid <= (Smi::MAX_SMI_VALUE >> HeapObject::CLASS_ID_OFFSET));
  uint16* classes = static_cast<uint16*>(malloc((cid + 1) * sizeof(uint16)));
  CXXV_ASSUME(classes != nullptr);
  classes[cid] = nondet_ushort();
  CXXV_ASSUME(Program::class_tag_from_class_bits(classes[cid]) == ARRAY_TAG);
  image.class_bits = List<uint16>(classes, cid + 1);
  image.set_array_class_id(Smi::from(cid));
  ObjectHeap* heap = new ObjectHeap(&image, nullptr, nullptr, nullptr, nullptr);
  CXXV_ASSUME(heap != nullptr);
  process_heap = heap;
  word length = nondet_word();
  array_witness = nondet_word();
  Object* filler = reinterpret_cast<Object*>(nondet_word());
  bool valid = 0 <= length && length <= Array::max_length_in_process();
  reserved_bytes = valid ? (2 + static_cast<uword>(length)) * WORD_SIZE : 0;
  TwoSpaceHeap& spaces = heap->two_space_heap_;
  spaces.process_heap_ = heap;
  bool retry = nondet_bool();
  heap->retrying_primitive_ = retry;
  bool large = nondet_bool();
  spaces.large_allocation_failed_ = large;
  uint64 total = static_cast<uint64>(nondet_int64());
  spaces.total_bytes_allocated_.store(total);
  // At most one space can grant storage in this call. Choose its source
  // independently of whether the primitive is eligible for an old-space retry.
  uword candidate = valid ? reinterpret_cast<uword>(malloc(reserved_bytes)) : 0;
  if (nondet_bool()) young_address = candidate;
  else if (nondet_bool()) old_address = candidate;
  bool fallback = valid && !young_address && retry;
  bool promoted = fallback && old_address;
  card = nondet_uchar();
  uint8 previous_card = card;
  GcMetadata::singleton_.remembered_set_bias_ =
      reinterpret_cast<uword>(&card) - old_address / GcMetadata::CARD_SIZE;
  uword address = young_address ? young_address : fallback ? old_address : 0;
  if (address) reserved = HeapObject::from_address(address);

  Array* result = heap->allocate_array(length, filler);
  CXXV_ASSERT(young_requests == (valid ? 1u : 0u) && old_requests == (fallback ? 1u : 0u) && result == reserved,
              "return the young reservation or retry in old space exactly on a retrying miss");
  CXXV_ASSERT(card == (promoted ? GcMetadata::NEW_SPACE_POINTERS : previous_card),
              "preserve the remembered card on every other outcome");
  CXXV_ASSERT(spaces.total_bytes_allocated_.load() == total + (promoted ? reserved_bytes : 0),
              "charge direct old-space array bytes exactly once");
  CXXV_ASSERT(spaces.large_allocation_failed_ == (large || (valid && !young_address && reserved_bytes >= TOIT_PAGE_SIZE / 2)),
              "classify large young-space misses using the array's full extent");
  if (result == nullptr) return 0;
  CXXV_ASSERT(result->class_id() == Smi::from(cid) && result->has_class_tag(ARRAY_TAG) &&
              result->length() == length, "initialize builtin array header and length");
  CXXV_ASSUME(0 <= array_witness && array_witness < length);
  CXXV_ASSERT(result->at(array_witness) == filler, "return the supplied filler at every index");
}
