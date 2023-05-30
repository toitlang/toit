// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests sending bigger chunks.

Setup:
Connect GND of one ESP32 to GND of another ESP32.
Connect pin 22 of the first ESP32 to pin 23 of the second ESP32.
Connect pin 23 of the first ESP32 to pin 22 of the second ESP32.

Run uart_big_data_read.toit on one ESP32 and uart_big_data_write.toit on the other.

For the host-test, use a flasher and connect GND to GND of the flasher.
Connect pin 22 of the ESP32 to the RX pin of the flasher.
Connect pin 23 of the ESP32 to the TX pin of the flasher.
If necessary, adjust the $UART_PATH.
*/

import expect show *

TEST_ITERATIONS := 10

RX ::= 22
TX ::= 23
UART_PATH ::= "/dev/ttyUSB1"
BAUD_RATE ::= 115200

TEST_BYTES := ByteArray 4096:
  b := it & 0xFF
  b == 0 ? it >> 8 : b

check_read_data data/ByteArray:
  expect_equals TEST_BYTES.size data.size
  if TEST_BYTES != data:
    for i := 0; i < TEST_BYTES.size; i++:
      if TEST_BYTES[i] != data[i]:
        print "Mismatch at $i: $TEST_BYTES[i] != $data[i]"
        print TEST_BYTES[max 0 (i - 3)..min data.size (i + 3)]
        print data[max 0 (i - 3)..min data.size (i + 3)]
  expect_equals TEST_BYTES data
