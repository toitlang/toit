// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests sending small data.

Run uart-small-data-board1.toit on one ESP32 and uart-small-data-board2.toit on the other.
*/

import crypto.md5
import expect show *
import io
import gpio
import system show platform
import system
import system.firmware
import uart

import .test
import .variants

RX1 ::= Variant.CURRENT.board-connection-pin1
TX1 ::= Variant.CURRENT.board-connection-pin2
RX2 ::= Variant.CURRENT.board-connection-pin2
TX2 ::= Variant.CURRENT.board-connection-pin1
BAUD-RATE ::= 115200

REPETITIONS ::= 3
ACK-BYTE ::= 99

main-board1:
  run-test: test-board1

test-board1:
  rx := gpio.Pin RX1
  tx := gpio.Pin TX1
  REPETITIONS.repeat:
    port := uart.Port --rx=rx --tx=tx --baud-rate=BAUD-RATE
    expected-size := port.in.little-endian.read-int32
    bytes16 := port.in.read-bytes 16
    received := 0
    while received < expected-size:
      received += port.in.read.size
    port.out.write-byte ACK-BYTE
    port.close

main-board2:
  run-test: test-board2

test-board2:
  rx := gpio.Pin RX2
  tx := gpio.Pin TX2
  REPETITIONS.repeat:
    size := it * 100 + 17
    data := ByteArray size: it & 255
    port := uart.Port --rx=rx --tx=tx --baud-rate=BAUD-RATE
    port.out.little-endian.write-int32 data.size
    port.out.write (ByteArray 16)
    port.out.write data
    port.out.flush
    ack := port.in.read-byte
    expect-equals 99 ACK-BYTE
    port.close
