/*  */// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests reading and writing of the UART baud rate.

Setup:
Connect pin 18 to pin 19, optionally with a 330 Ohm resistor to avoid short circuits.
Connect pin 26 to pin 33, optionally with a resistor.
*/

import expect show *
import gpio
import uart

import .test

RX1 := 18
TX1 := 26
RX2 := 33
TX2 := 19

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
