// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests reading and writing of the UART baud rate.

For the setup see the comment near $Variant.uart-baud-rate-in1.
*/

import expect show *
import gpio
import uart

import .test
import .variants

// Note that RX1 goes to TX2 and TX1 goes to RX2.
RX1 ::= Variant.CURRENT.uart-baud-rate-in2
TX1 ::= Variant.CURRENT.uart-baud-rate-out1

RX2 ::= Variant.CURRENT.uart-baud-rate-in1
TX2 ::= Variant.CURRENT.uart-baud-rate-out2

expect-baud expected/int actual/int:
  // Baudrate is not 100% accurate, so we can't just test for equality to $expected.
  // https://github.com/espressif/esp-idf/issues/3885
  expect (expected - 5) <= actual <= (expected + 5)

main:
  run-test: test

test:
  port1 := uart.Port
      --rx=gpio.Pin RX1
      --tx=gpio.Pin TX1
      --baud-rate=9600

  port2 := uart.Port
      --rx=gpio.Pin RX2
      --tx=gpio.Pin TX2
      --baud-rate=9600

  port1.out.write "toit" --flush
  bytes := port2.in.read
  expect-equals "toit" bytes.to-string

  expect-baud 9600 port1.baud-rate
  expect-baud 9600 port2.baud-rate

  port1.baud-rate = 115200
  expect-baud 115200 port1.baud-rate
  expect-baud 9600 port2.baud-rate

  port2.baud-rate = 115200
  expect-baud 115200 port2.baud-rate

  written := port1.out.write "like a" --flush
  expect-equals 6 written
  bytes = port2.in.read
  expect-equals "like a" bytes.to-string

  port2.out.write "tiger" --flush
  bytes = port1.in.read
  expect-equals "tiger" bytes.to-string

  port1.close
  port2.close
