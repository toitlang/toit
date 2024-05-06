// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests sending bigger chunks.

Setup:
Connect GND of one ESP32 to GND of another ESP32.
Connect pin 22 of the first ESP32 to pin 23 of the second ESP32.
Connect pin 23 of the first ESP32 to pin 22 of the second ESP32.

Run uart-big-data-board1.toit on one ESP32 and uart-big-data-board2.toit on the other.

For the host-test, use a flasher and connect GND to GND of the flasher.
Connect pin 22 of the ESP32 to the RX pin of the flasher.
Connect pin 23 of the ESP32 to the TX pin of the flasher.
If necessary, adjust the $UART-PATH.
*/

import expect show *

TEST-ITERATIONS := 10

RX ::= 22
TX ::= 23
UART-PATH ::= "/dev/ttyUSB1"
BAUD-RATE ::= 115200

TEST-BYTES := ByteArray 4096:
  b := it & 0xFF
  b == 0 ? it >> 8 : b

check-read-data data/ByteArray:
  expect-equals TEST-BYTES.size data.size
  if TEST-BYTES != data:
    for i := 0; i < TEST-BYTES.size; i++:
      if TEST-BYTES[i] != data[i]:
        print "Mismatch at $i: $TEST-BYTES[i] != $data[i]"
        print TEST-BYTES[max 0 (i - 3)..min data.size (i + 3)]
        print data[max 0 (i - 3)..min data.size (i + 3)]
  expect-equals TEST-BYTES data
