// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "primitive_bitmap.cc"

using namespace toit;

// The lookup occupies the middle 256 bytes. Source and destination can
// overlap it or one another, including the second byte of a wide write.

int main() {
  static_assert(sizeof(word) * 8 == CXXV_WORD_BITS, "target word width");
  uint8 bytes[260];
  unsigned s = nondet_uint();
  unsigned d = nondet_uint();
  unsigned witness = nondet_uint();
  word op = nondet_word();
  CXXV_ASSUME(s < sizeof(bytes) && d < sizeof(bytes) && witness < sizeof(bytes));
  CXXV_ASSUME(0 <= op && op < NUMBER_OF_POSSIBLE_OPERATIONS);
  CXXV_ASSUME(op != ADD_16_LE || d + 1 < sizeof(bytes));
  word shift = nondet_word();
  word mask = nondet_word();
  uint8* table = bytes + 2;
  // Initialize exactly the observable input bytes. Initialize the selected
  // table entry last. When it aliases the source, both names hold one byte.
  bytes[witness] = nondet_uchar();
  bytes[d] = nondet_uchar();
  if (op == ADD_16_LE) bytes[d+1] = nondet_uchar();
  bytes[s] = nondet_uchar();
  unsigned source_value = bytes[s];
  uint8 mapped_byte = nondet_uchar();
  CXXV_ASSUME(table + source_value != bytes + s || mapped_byte == source_value);
  table[source_value] = mapped_byte;
  if (nondet_bool()) table = nullptr;
  unsigned mapped = table == nullptr ? bytes[s] : table[bytes[s]];
  unsigned amount = static_cast<uword>(shift) % 8;
  unsigned operand = ((mapped * 257u) >> amount) & static_cast<unsigned>(mask);
  unsigned before = bytes[d];
  unsigned untouched = bytes[witness];
  unsigned expected;
  switch (op) {
    case OVERWRITE: expected = operand; break;
    case OR: expected = before | operand; break;
    case AND: expected = before & operand; break;
    case XOR: expected = before ^ operand; break;
    case ADD: expected = before + operand > 255 ? 255 : before + operand; break;
    default: {
      unsigned sum = before + 256u * bytes[d+1] + operand;
      expected = sum > 65535 ? 65535 : sum;
    }
  }

  blit_pixel(bytes, s, bytes, d, table, shift, mask, op);
  CXXV_ASSERT(bytes[d] == (expected & 255), "destination low byte");
  if (op == ADD_16_LE) CXXV_ASSERT(bytes[d+1] == expected / 256, "destination high byte");
  if (witness != d && (op != ADD_16_LE || witness != d+1)) {
    CXXV_ASSERT(bytes[witness] == untouched, "every other byte is preserved");
  }
}
