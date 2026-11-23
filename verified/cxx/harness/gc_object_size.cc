// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "objects.cc"
#undef protected
#undef private

using namespace toit;

extern Program image;
GcMetadata GcMetadata::singleton_;

class OneWordRoots : public RootCallback {
 public:
  void do_roots(Object**, word count) override {
    CXXV_ASSERT(count == 0, "one-word objects have no outgoing root slots");
  }

  bool skip_marking(HeapObject*) const override { return false; }
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  TypeTag tag = static_cast<TypeTag>(nondet_int());
  CXXV_ASSUME(tag >= ARRAY_TAG && tag <= PROMOTED_TRACK_TAG);
  // Supply storage for header fields independently of the represented payload length.
  auto* raw = static_cast<uword*>(malloc(8 * WORD_SIZE));
  CXXV_ASSUME(raw != nullptr && reinterpret_cast<uword>(raw) % WORD_SIZE == 0);
  auto* object = HeapObject::from_address(reinterpret_cast<uword>(raw));
  int cid = nondet_int();
  CXXV_ASSUME(cid >= 0 && cid < INT_MAX && cid <= (Smi::MAX_SMI_VALUE >> HeapObject::CLASS_ID_OFFSET));
  if (tag == FREE_LIST_REGION_TAG) cid = FREE_LIST_REGION_CLASS_ID;
  if (tag == SINGLE_FREE_WORD_TAG) cid = SINGLE_FREE_WORD_CLASS_ID;
  if (tag == PROMOTED_TRACK_TAG) cid = PROMOTED_TRACK_CLASS_ID;
  object->_set_header(Smi::from(cid), tag);
  if (nondet_bool()) object->set_has_active_finalizer();

  word n = nondet_word();
  CXXV_ASSUME(n >= 0);
  word expected;
  int fixed = 0;
  switch (tag) {
    case INSTANCE_TAG:
    case TASK_TAG:
    case ODDBALL_TAG:
      CXXV_ASSUME(n >= 1 && n <= Program::INSTANCE_SIZE_MASK);
      fixed = n * WORD_SIZE;
      expected = fixed;
      break;
    case DOUBLE_TAG:
    case LARGE_INTEGER_TAG:
      expected = WORD_SIZE + 8;
      fixed = nondet_bool() ? expected : 0;
      break;
    case ARRAY_TAG:
    case STACK_TAG: {
      word header = tag == ARRAY_TAG ? 2 * WORD_SIZE : Stack::HEADER_SIZE;
      CXXV_ASSUME(n <= (INTPTR_MAX - header) / WORD_SIZE);
      if (tag == ARRAY_TAG) static_cast<Array*>(object)->_set_length(n);
      else static_cast<Stack*>(object)->_set_length(n);
      expected = header + n * WORD_SIZE;
      break;
    }
    case BYTE_ARRAY_TAG:
    case STRING_TAG: {
      bool external = nondet_bool();
      word extra = tag == STRING_TAG ? 1 : 0;  // Strings have a terminating byte.
      if (!external) {
        CXXV_ASSUME(n <= INTPTR_MAX - 3 * WORD_SIZE);
        if (tag == STRING_TAG) CXXV_ASSUME(n < String::SENTINEL);
      }
      if (tag == BYTE_ARRAY_TAG) {
        static_cast<ByteArray*>(object)->_set_length(external ? -1 - n : n);
      } else {
        static_cast<String*>(object)->_set_length(external ? String::SENTINEL : n);
      }
      expected = external ? 4 * WORD_SIZE : (2 + (n + extra + WORD_SIZE - 1) / WORD_SIZE) * WORD_SIZE;
      break;
    }
    case SINGLE_FREE_WORD_TAG:
      expected = WORD_SIZE;
      break;
    case FREE_LIST_REGION_TAG:
    case PROMOTED_TRACK_TAG:
      CXXV_ASSUME(n >= 3 && n <= INTPTR_MAX / WORD_SIZE);
      expected = n * WORD_SIZE;
      if (tag == FREE_LIST_REGION_TAG) {
        object->_word_at_put(FreeListRegion::SIZE_OFFSET, expected);
      } else {
        uword base = reinterpret_cast<uword>(raw);
        CXXV_ASSUME(base <= UINTPTR_MAX - expected);
        static_cast<PromotedTrack*>(object)->set_end(base + expected);
      }
      break;
    default:
      CXXV_ASSERT(false, "all native heap tags have an extent");
      return 1;
  }
  if (cid >= 0) {
    size_t count = static_cast<size_t>(cid) + 1;
    auto* table = static_cast<uint16*>(malloc(count * sizeof(uint16)));
    CXXV_ASSUME(table != nullptr);
    image.class_bits = List<uint16>(table, count);
    table[cid] = Program::compute_class_bits(tag, fixed);
  }
  word size = object->size(&image);
  CXXV_ASSERT(size == expected && size > 0 && size % WORD_SIZE == 0,
              "native size returns the exact positive word-aligned extent of each valid representation");

  // The overflow walker recognizes a grey object by its first two mark bits.
  // The second bit may belong to a different object if this object has one word.
  uword address = reinterpret_cast<uword>(raw);
  uword card = address / GcMetadata::CARD_SIZE;
  uint32 marks[2] = {nondet_uint(), nondet_uint()};
  GcMetadata::singleton_.mark_bits_bias_ = reinterpret_cast<uword>(marks) - card * sizeof(uint32);
  unsigned index = (address / WORD_SIZE) % 32;
  marks[0] |= uint32{1} << index;  // This object was discovered.
  bool second_marked = ((marks[(index + 1) / 32] >> ((index + 1) % 32)) & 1U) != 0;
  bool grey = GcMetadata::is_grey(object);
  if (size == WORD_SIZE) {
    OneWordRoots visitor;
    object->roots_do(&image, &visitor);
    CXXV_ASSERT(GcMetadata::is_marked(object), "a discovered one-word object's complete extent is marked");
  } else {
    CXXV_ASSERT(grey == !second_marked, "the overflow test reads the second bit inside the discovered object");
  }
}
