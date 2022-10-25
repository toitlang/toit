/*  */// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests reading and writing of the UART baud rate.

Setup:
Connect pin 16 to pin 26, optionally with a 330 Ohm resistor to avoid short circuits.
Connect pin 17 to pin 27, optionally with a resistor.
*/

import expect show *
import gpio
import uart

RX1 := 16
TX1 := 17
RX2 := 27
TX2 := 26

expect_baud expected/int actual/int:
  // Baudrate is not 100% accurate, so we can't just test for equality to $expected.
  // https://github.com/espressif/esp-idf/issues/3885
  expect (expected - 5) <= actual <= (expected + 5)

main:
  port1 := uart.Port
      --rx=gpio.Pin RX1
      --tx=gpio.Pin TX1
      --baud_rate=9600

  port2 := uart.Port
      --rx=gpio.Pin RX2
      --tx=gpio.Pin TX2
      --baud_rate=9600

  // We expect all messages to go through in one go.
  // As such we don't buffer or use a Writer.

  port1.write "toit" --wait
  bytes := port2.read
  expect_equals "toit" bytes.to_string

  expect_baud 9600 port1.baud_rate
  expect_baud 9600 port2.baud_rate

  port1.baud_rate = 115200
  expect_baud 115200 port1.baud_rate
  expect_baud 9600 port2.baud_rate

  port2.baud_rate = 115200
  expect_baud 115200 port2.baud_rate

  port1.write "like a" --wait
  bytes = port2.read
  expect_equals "like a" bytes.to_string

  port2.write "tiger" --wait
  bytes = port1.read
  expect_equals "tiger" bytes.to_string

  print "done"

  port1.close
  port2.close
