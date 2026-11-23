// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "float_payload.h"
static void observe_free(void* p) {
  CXXV_ASSERT(p == nullptr, "fixed scalar has no owned storage to dispose");
}
#define free observe_free
#define private public
#define protected public
#include "ipc_scalar_messaging.inc"
#undef protected
#undef private
#undef free

using namespace toit;

extern Program sender_image;
extern Program receiver_image;
extern Process sender;
extern Process receiver;
static uint64 expected_bits;
static uint8 expected_tag;
static unsigned allocations;
static bool allocation_fails;
static uword result_words[1 + 8 / WORD_SIZE];

static HeapObject* allocation(uint64 bits, uint8 tag) {
  ++allocations;
  CXXV_ASSERT(allocations == 1 && tag == expected_tag &&
              (tag == TAG_DOUBLE ? same_double_payload(bits, expected_bits) : bits == expected_bits),
              "allocate exactly one box of the decoded type with the original numeric value");
  return allocation_fails ? nullptr : HeapObject::from_address(reinterpret_cast<uword>(result_words));
}

Double* ObjectHeap::allocate_double(double value) {
  return static_cast<Double*>(allocation(bit_cast<uint64>(value), TAG_DOUBLE));
}

LargeInteger* ObjectHeap::allocate_large_integer(int64 value) {
  return static_cast<LargeInteger*>(allocation(bit_cast<uint64>(value), TAG_LARGE_INTEGER));
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  static_assert(MESSAGING_ENCODING_MAX_NESTING <= MESSAGING_DECODING_MAX_NESTING, "receiver admits sender depth");
  uword roots[] = {2 * ODDBALL_TAG, 2 * ODDBALL_TAG, 2 * ODDBALL_TAG};
  sender_image.set_null_object(HeapObject::from_address(reinterpret_cast<uword>(roots)));
  sender_image.set_true_object(HeapObject::from_address(reinterpret_cast<uword>(roots + 1)));
  sender_image.set_false_object(HeapObject::from_address(reinterpret_cast<uword>(roots + 2)));
  sender.program_ = &sender_image;
  uword receiver_roots[] = {2 * ODDBALL_TAG, 2 * ODDBALL_TAG, 2 * ODDBALL_TAG};
  receiver_image.set_null_object(HeapObject::from_address(reinterpret_cast<uword>(receiver_roots)));
  receiver_image.set_true_object(HeapObject::from_address(reinterpret_cast<uword>(receiver_roots + 1)));
  receiver_image.set_false_object(HeapObject::from_address(reinterpret_cast<uword>(receiver_roots + 2)));
  receiver.program_ = &receiver_image;
  int kind = nondet_int();
  CXXV_ASSUME(0 <= kind && kind < 5);
  uword box[1 + 8 / WORD_SIZE];
  Object* input;
  if (kind < 3) {
    input = HeapObject::from_address(reinterpret_cast<uword>(roots + kind));
    expected_tag = kind == 0 ? TAG_NULL : kind == 1 ? TAG_TRUE : TAG_FALSE;
  } else {
    expected_bits = bit_cast<uint64>(nondet_int64());
    memcpy(box + 1, &expected_bits, sizeof(expected_bits));
    box[0] = 2 * (kind == 3 ? DOUBLE_TAG : LARGE_INTEGER_TAG);
    input = HeapObject::from_address(reinterpret_cast<uword>(box));
    expected_tag = kind == 3 ? TAG_DOUBLE : TAG_LARGE_INTEGER;
  }
  int depth = nondet_int();
  CXXV_ASSUME(0 <= depth && depth < MESSAGING_ENCODING_MAX_NESTING);
  MessageEncoder sizing(&sender, nullptr);
  sizing.nesting_ = depth;
  bool sized = sizing.encode(input);
  word extent = kind < 3 ? 1 : 9;
  CXXV_ASSERT(sized && sizing.size() == extent && sizing.total_size() == extent &&
              sizing.externals_count() == 0, "sizing charges exactly the wire extent");
  uint8 bytes[extent];
  MessageEncoder writing(&sender, bytes, MESSAGE_FORMAT_IPC, false);
  writing.nesting_ = depth;
  bool written = writing.encode(input);
  CXXV_ASSERT(written && writing.size() == extent && writing.total_size() == extent &&
              writing.copied_count_ == 0 && writing.transferred_count_ == 0 &&
              writing.externals_count() == 0 && bytes[0] == expected_tag,
              "writing fits the sized envelope with the correct tag and no owners");
  if (nondet_bool()) {
    MessageDecoder cleanup(bytes);
    cleanup.deallocate();
    CXXV_ASSERT(cleanup.success() && cleanup.cursor_ == extent, "dispose the complete scalar");
    return 0;
  }
  allocation_fails = nondet_bool();
  MessageDecoder reader(&receiver, bytes, extent, MESSAGE_FORMAT_IPC);
  reader.nesting_ = depth;
  Object* result = reader.decode();
  bool needs_box = kind == 3 || (kind == 4 && !Smi::is_valid(bit_cast<int64>(expected_bits)));
  CXXV_ASSERT(allocations == (needs_box ? 1 : 0) && reader.cursor_ == extent && reader.externals_count() == 0,
              "consume the entire scalar and allocate only when required");
  if (needs_box && allocation_fails) {
    CXXV_ASSERT(result == nullptr && reader.allocation_failed(), "report receiver allocation failure");
  } else {
    CXXV_ASSERT(reader.success(), "successful scalar decode");
    if (needs_box) {
      CXXV_ASSERT(result == HeapObject::from_address(reinterpret_cast<uword>(result_words)), "return allocated box");
    } else if (kind < 3) {
      CXXV_ASSERT(result == HeapObject::from_address(reinterpret_cast<uword>(receiver_roots + kind)),
                  "select the corresponding root of the receiving image");
    } else {
      CXXV_ASSERT(is_smi(result) && Smi::value(result) == bit_cast<int64>(expected_bits), "canonical tagged integer");
    }
  }
}
