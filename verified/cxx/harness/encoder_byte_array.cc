// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "encoder.cc"

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  // Only the first 40 bytes may be inspected, even for a longer declared length.
  uword words[2 + 40 / sizeof(word)];
  uint8 external_bytes[40];
  bool external = nondet_bool();
  word length = nondet_word();
  CXXV_ASSUME(length >= 0);
  word tag = nondet_word();
  bool proxy = external && tag != RawByteTag;
  words[0] = 2 * BYTE_ARRAY_TAG;
  words[1] = external ? static_cast<uword>(-1 - length) : static_cast<uword>(length);
  if (external) {
    words[2] = proxy ? 0 : reinterpret_cast<uword>(external_bytes);
    words[3] = static_cast<uword>(tag);
  }
  word count = proxy ? 0 : (length < 40 ? length : 40);
  word witness = nondet_word();
  CXXV_ASSUME(witness >= 0 && witness < 40);
  uint8 expected = nondet_uchar();
  uint8* payload = external ? external_bytes : reinterpret_cast<uint8*>(words + 2);
  payload[witness] = expected;
  auto* array = static_cast<ByteArray*>(HeapObject::from_address(reinterpret_cast<uword>(words)));

  MallocedBuffer output(46);
  CXXV_ASSUME(output.has_content());
  Encoder encoder(&output);
  encoder.write_byte_array(array);
  uint8* data = output.content();
  CXXV_ASSERT(output.size() == 6 + count, "encoded size equals header plus capped length");
  CXXV_ASSERT(data[0] == '[' && data[1] == '$' && data[2] == 'U' && data[3] == '#' &&
              data[4] == 'U' && data[5] == count, "typed byte-array header and exact payload length");
  if (witness < count) {
    CXXV_ASSERT(data[6 + witness] == expected, "every emitted payload byte equals its source");
  }
}
