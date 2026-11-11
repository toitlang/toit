// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// MessageDecoder::decode_process_message decodes the exit value of a
// TERMINATED system message without a process (the scheduler, when there is
// no boot process). Any unrestricted process can send a TERMINATED system
// message with any content, and the decoder used to decode it in full: for
// anything but a smi it dereferenced the missing process or program (null,
// true and false are the program's objects; strings, arrays and large
// integers are allocated in the process). Now only an integer in the range
// of 'int' is read, anything else is refused.

#include <stdlib.h>
#include <string.h>

#include "../../src/top.h"
#include "../../src/messaging.h"

namespace toit {

// The tags of src/messaging.cc.
static const uint8 TAG_POSITIVE_SMI = 1;
static const uint8 TAG_NEGATIVE_SMI = 2;
static const uint8 TAG_NULL = 3;
static const uint8 TAG_ARRAY = 6;
static const uint8 TAG_LARGE_INTEGER = 8;
static const uint8 TAG_STRING_INLINE = 11;

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
  // What the VM sends: encode_process_message.
  uint8 buffer[MESSAGING_PROCESS_MESSAGE_SIZE];
  const int values[] = { 0, 1, 42, 127, 128, 255 };
  for (int value : values) {
    memset(buffer, 0, sizeof(buffer));
    MessageEncoder::encode_process_message(buffer, value);
    expect_value(buffer, value, __LINE__);
  }

  const uint8 negative[] = { TAG_NEGATIVE_SMI, 5 };
  expect_value(negative, -5, __LINE__);
  // INT_MAX and -INT_MAX are the largest magnitudes.
  const uint8 int_max[] = { TAG_POSITIVE_SMI, 0xff, 0xff, 0xff, 0xff, 0x07 };
  expect_value(int_max, INT_MAX, __LINE__);
  const uint8 minus_int_max[] = { TAG_NEGATIVE_SMI, 0xff, 0xff, 0xff, 0xff, 0x07 };
  expect_value(minus_int_max, -INT_MAX, __LINE__);
  // 2^31: not an int.
  const uint8 too_large[] = { TAG_POSITIVE_SMI, 0x80, 0x80, 0x80, 0x80, 0x08 };
  expect_refused(too_large, __LINE__);
  // 2^40: a smi of a 64-bit VM.
  const uint8 smi_64[] = { TAG_POSITIVE_SMI, 0x80, 0x80, 0x80, 0x80, 0x80, 0x20 };
  expect_refused(smi_64, __LINE__);
  // A cardinal with bits beyond the word: malformed.
  const uint8 malformed[] = { TAG_POSITIVE_SMI, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f };
  expect_refused(malformed, __LINE__);

  // The other kinds used to dereference the missing process or program.
  const uint8 null_object[] = { TAG_NULL };
  expect_refused(null_object, __LINE__);
  const uint8 string[] = { TAG_STRING_INLINE, 2, 'h', 'i' };
  expect_refused(string, __LINE__);
  const uint8 array[] = { TAG_ARRAY, 1, TAG_POSITIVE_SMI, 0 };
  expect_refused(array, __LINE__);
  const uint8 large_integer[] = { TAG_LARGE_INTEGER, 1, 0, 0, 0, 0, 0, 0, 0 };
  expect_refused(large_integer, __LINE__);
}

}  // namespace toit

int main(int argc, char** argv) {
  toit::run();
  return 0;
}
