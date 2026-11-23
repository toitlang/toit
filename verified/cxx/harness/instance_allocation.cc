// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "objects_inline.h"
namespace toit { static void apply_field_fill(Object**, uword, Object*); }
#include "instance_heap.inc"
#undef protected
#undef private

using namespace toit;

extern Program image;
static uword storage[Program::INSTANCE_SIZE_MASK + 2];
static unsigned words, witness;
static unsigned fills;
static Object* null_value;

// The two-width VeriFast proof of Utils::fill_words grants the supplied
// value in every slot. Instantiate it at an arbitrary word in the page.
void toit::apply_field_fill(Object** first, uword count, Object* value) {
  CXXV_ASSERT(first == reinterpret_cast<Object**>(storage + 1) && words > 0 && count == words - 1 &&
              value == null_value && fills == 0, "fill exactly the granted instance payload with program null");
  ++fills;
  if (witness > 0 && witness < words) first[witness - 1] = value;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  word cid = nondet_word();
  CXXV_ASSUME(0 <= cid && cid <= (Smi::MAX_SMI_VALUE >> HeapObject::CLASS_ID_OFFSET));
  CXXV_ASSUME(cid < INT32_MAX);
  uint16 classes[cid + 1];
  uint16 bits = nondet_ushort();
  classes[cid] = bits;
  words = bits >> HeapObject::CLASS_ID_OFFSET;
  image.class_bits = List<uint16>(classes, cid + 1);
  uword null_header = 0;
  auto* root = HeapObject::from_address(reinterpret_cast<uword>(&null_header));
  image.set_null_object(root);
  null_value = root;
  auto* heap = new ObjectHeap(&image, nullptr, nullptr, nullptr, nullptr);
  CXXV_ASSUME(heap != nullptr);
  auto* space = heap->two_space_heap_.new_space();
  unsigned available = nondet_uint();
  CXXV_ASSUME(available <= Program::INSTANCE_SIZE_MASK + 1);
  space->top_ = reinterpret_cast<uword>(storage);
  space->limit_ = space->top_ + available * WORD_SIZE;
  witness = nondet_uint();
  CXXV_ASSUME(witness <= Program::INSTANCE_SIZE_MASK + 1);
  uword prior = nondet_ulong();
  storage[witness] = prior;
  auto* result = heap->allocate_instance(Smi::from(cid));
  bool success = words != 0 && words < available;
  CXXV_ASSERT(result == (success ? HeapObject::from_address(reinterpret_cast<uword>(storage)) : nullptr) &&
              fills == static_cast<unsigned>(success), "grant only a nonempty instance with room for the sentinel");
  CXXV_ASSERT(space->top_ == reinterpret_cast<uword>(storage + (success ? words : 0)), "advance by its exact size");
  if (success && witness == 0) {
    CXXV_ASSERT(result->class_id() == Smi::from(cid) && result->has_class_tag(Program::class_tag_from_class_bits(bits)),
                "construct the requested class header");
  } else if (success && witness < words) {
    CXXV_ASSERT(reinterpret_cast<Object**>(storage)[witness] == null_value, "every instance field starts at program null");
  } else if (success && witness == words) {
    CXXV_ASSERT(has_sentinel_at(space->top_), "the sentinel follows the instance");
  } else {
    CXXV_ASSERT(storage[witness] == prior, "preserve unallocated words and all storage on refusal");
  }
}
