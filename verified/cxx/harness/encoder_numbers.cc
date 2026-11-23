// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "encoder.cc"

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  MallocedBuffer output(10);
  CXXV_ASSUME(output.has_content());
  Encoder encoder(&output);
  int64 value = nondet_int64();
  unsigned width;
  uint8 tag;
  unsigned start = 1;
  uint8* data = output.content();
  unsigned mode = nondet_uint();
  CXXV_ASSUME(mode < 4);
  if (mode == 0) {
    encoder.write_int(value);
    // The existing wire format uses the eight-byte form for INT32_MIN.
    if (0 <= value && value <= UINT8_MAX) {
      width = 1;
      tag = 'U';
    } else if (INT8_MIN <= value && value <= INT8_MAX) {
      width = 1;
      tag = 'i';
    } else if (INT16_MIN <= value && value <= INT16_MAX) {
      width = 2;
      tag = 'I';
    } else if (INT32_MIN < value && value <= INT32_MAX) {
      width = 4;
      tag = 'l';
    } else {
      width = 8;
      tag = 'L';
    }
  } else if (mode == 1) {
    CXXV_ASSUME(INT32_MIN < value && value <= INT32_MAX);
    encoder.write_int32(value);
    width = 4;
    tag = 'l';
  } else if (mode == 2) {
    // The bit pattern includes signed zeros, infinities and NaN payloads.
    encoder.write_double(bit_cast<double>(value));
    width = 8;
    tag = 'D';
  } else {
    word members = nondet_word();
    CXXV_ASSUME(members >= 0 && members < INT32_MAX);
    uint8 object_tag = nondet_uchar();
    encoder.write_header(members, object_tag);
    CXXV_ASSERT(data[0] == '[' && data[1] == '#' && data[7] == 'U' && data[8] == object_tag,
                "collection header includes the original object tag");
    value = static_cast<int64>(members) + 1;
    start = 3;
    width = 4;
    tag = 'l';
  }
  CXXV_ASSERT(output.size() == (mode == 3 ? 9 : width + 1) && data[start - 1] == tag,
              "wire tag and encoded length");
  unsigned index = nondet_uint();
  CXXV_ASSUME(index < width);
  uint64 bits = static_cast<uint64>(value);
  CXXV_ASSERT(data[start + index] == static_cast<uint8>(bits >> (8 * (width - 1 - index))),
              "each payload byte is in big-endian order");
}
