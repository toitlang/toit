// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// MessageDecoder::decode_external_data decodes the messages for external
// message handlers. The length of an inline byte array or string must fit
// the message: a length above INT_MAX used to become a negative int (and
// then a copy of almost SIZE_MAX bytes), and INT_MAX itself overflowed the
// length of the string's copy. The encoder only inlines small contents, so
// these messages are crafted.

#include <stdlib.h>
#include <string.h>

#include "../../src/top.h"
#include "../../src/messaging.h"

namespace toit {

// The tags of src/messaging.cc.
static const uint8 TAG_STRING_INLINE = 11;
static const uint8 TAG_BYTE_ARRAY_INLINE = 13;

// Compares the first 'copied_length' bytes of the copy with 'expected'.
static void expect_data(const uint8* buffer, const char* expected, word expected_length, word copied_length, int line) {
  MessageDecoder decoder(buffer);
  void* data = null;
  word length = -1;
  if (!decoder.decode_external_data(&data, &length)) {
    FATAL("line %d: not decoded", line);
  }
  if (length != expected_length || memcmp(data, expected, copied_length) != 0) {
    FATAL("line %d: wrong data", line);
  }
  free(data);
}

static void expect_malformed(const uint8* buffer, int line) {
  MessageDecoder decoder(buffer);
  void* data = null;
  word length = -1;
  if (decoder.decode_external_data(&data, &length)) {
    FATAL("line %d: decoded %ld bytes", line, static_cast<long>(length));
  }
  if (!decoder.malformed_input()) {
    FATAL("line %d: not malformed", line);
  }
}

static void run() {
  const uint8 byte_array[] = { TAG_BYTE_ARRAY_INLINE, 3, 'a', 'b', 'c' };
  expect_data(byte_array, "abc", 3, 3, __LINE__);
  const uint8 empty_byte_array[] = { TAG_BYTE_ARRAY_INLINE, 0 };
  expect_data(empty_byte_array, "", 0, 0, __LINE__);
  const uint8 string[] = { TAG_STRING_INLINE, 2, 'h', 'i' };
  // The copy of a string is '\0'-terminated.
  expect_data(string, "hi", 2, 3, __LINE__);

  // 2^31: negative as an int.
  const uint8 byte_array_2_31[] = { TAG_BYTE_ARRAY_INLINE, 0x80, 0x80, 0x80, 0x80, 0x08, 'a' };
  expect_malformed(byte_array_2_31, __LINE__);
  const uint8 string_2_31[] = { TAG_STRING_INLINE, 0x80, 0x80, 0x80, 0x80, 0x08, 'a' };
  expect_malformed(string_2_31, __LINE__);
  // INT_MAX: longer than any message, and its '\0' overflows an int.
  const uint8 byte_array_int_max[] = { TAG_BYTE_ARRAY_INLINE, 0xff, 0xff, 0xff, 0xff, 0x07, 'a' };
  expect_malformed(byte_array_int_max, __LINE__);
  const uint8 string_int_max[] = { TAG_STRING_INLINE, 0xff, 0xff, 0xff, 0xff, 0x07, 'a' };
  expect_malformed(string_int_max, __LINE__);
}

}  // namespace toit

int main(int argc, char** argv) {
  toit::run();
  return 0;
}
