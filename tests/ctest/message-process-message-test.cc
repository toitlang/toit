// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// MessageDecoder::decode_process_message decodes the exit value of a
// TERMINATED system message without a process. The scheduler calls it when
// there is no boot process. Any process can send a TERMINATED system message
// with any content (process_send with a negative pid), so the decoder must
// refuse everything but an integer instead of dereferencing the missing
// process or program.

#include <string.h>

#include "../../src/top.h"
#include "../../src/messaging.h"

namespace toit {

// The tags of src/messaging.cc.
static const uint8 TAG_POSITIVE_SMI = 1;
static const uint8 TAG_NEGATIVE_SMI = 2;
static const uint8 TAG_NULL = 3;
static const uint8 TAG_TRUE = 4;
static const uint8 TAG_ARRAY = 6;
static const uint8 TAG_DOUBLE = 7;
static const uint8 TAG_LARGE_INTEGER = 8;
static const uint8 TAG_STRING_INLINE = 11;
static const uint8 TAG_BYTE_ARRAY_INLINE = 13;

static void expect_value(const uint8* buffer, int expected, int line) {
  int value = -1;
  if (!MessageDecoder::decode_process_message(buffer, &value) || value != expected) {
    FATAL("line %d: expected %d, got %d", line, expected, value);
  }
}

static void expect_refused(const uint8* buffer, int line) {
  int value = 0;
  if (MessageDecoder::decode_process_message(buffer, &value)) {
    FATAL("line %d: decoded %d", line, value);
  }
}

static void run() {
  // What the VM sends.
  const int values[] = { 0, 1, 42, 127, 128, 255 };
  for (int value : values) {
    uint8 buffer[MESSAGING_PROCESS_MESSAGE_SIZE];
    memset(buffer, 0, sizeof(buffer));
    MessageEncoder::encode_process_message(buffer, value);
    expect_value(buffer, value, __LINE__);
  }

  // What a process can send with process_send.
  const uint8 negative[] = { TAG_NEGATIVE_SMI, 5 };
  expect_value(negative, -5, __LINE__);
  const uint8 int_max[] = { TAG_POSITIVE_SMI, 0xff, 0xff, 0xff, 0xff, 0x07 };
  expect_value(int_max, INT_MAX, __LINE__);
  const uint8 minus_int_max[] = { TAG_NEGATIVE_SMI, 0xff, 0xff, 0xff, 0xff, 0x07 };
  expect_value(minus_int_max, -INT_MAX, __LINE__);
  // 2^31 and 2^40 don't fit an int (they used to be truncated on 64-bit).
  const uint8 two_31[] = { TAG_POSITIVE_SMI, 0x80, 0x80, 0x80, 0x80, 0x08 };
  expect_refused(two_31, __LINE__);
  const uint8 two_40[] = { TAG_POSITIVE_SMI, 0x80, 0x80, 0x80, 0x80, 0x80, 0x20 };
  expect_refused(two_40, __LINE__);

  // These used to dereference the missing program or process.
  const uint8 null_object[] = { TAG_NULL };
  expect_refused(null_object, __LINE__);
  const uint8 true_object[] = { TAG_TRUE };
  expect_refused(true_object, __LINE__);
  const uint8 string[] = { TAG_STRING_INLINE, 2, 'h', 'i' };
  expect_refused(string, __LINE__);
  const uint8 byte_array[] = { TAG_BYTE_ARRAY_INLINE, 1, 0 };
  expect_refused(byte_array, __LINE__);
  const uint8 array[] = { TAG_ARRAY, 1, TAG_POSITIVE_SMI, 0 };
  expect_refused(array, __LINE__);
  const uint8 double_object[] = { TAG_DOUBLE, 0, 0, 0, 0, 0, 0, 0, 0 };
  expect_refused(double_object, __LINE__);
  const uint8 large_integer[] = { TAG_LARGE_INTEGER, 0, 0, 0, 0, 0, 0, 0, 0x40 };
  expect_refused(large_integer, __LINE__);
}

}  // namespace toit

int main(int argc, char** argv) {
  toit::run();
  return 0;
}
