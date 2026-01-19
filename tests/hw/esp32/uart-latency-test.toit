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
import rmt

import .test
import .variants

TX ::= Variant.CURRENT.connected1-pin1
RX ::= Variant.CURRENT.connected1-pin2

main:
  print "TX: $TX, RX: $RX"
  run-test: test

test:
  // Configure the UART similar to what we do for the pixel strip.
  port1 := uart.Port
      --rx=null
      --tx=gpio.Pin TX
      --data-bits=7
      --baud-rate=2_500_000

  channel := rmt.In (gpio.Pin RX)
      --resolution=4_000_000
      --memory-blocks=2

  data := ByteArray 1024 --initial=0xAA
  data[1022] = 0xFF
  data[1023] = 0

  // At 2_500_00 baud, a bit takes 400 ns. We filter out anything that is shorter
  // than 1000 ns.
  // If a byte has 0xAA, then the bits alternate too fast and will be ignored.
  // Our data has a 0xFF at 1022, which is longer than 1000 ns and will be detected.
  // If, at any time, there is a gap between sequences that are written to the UART, then
  // the TX line will be high. If that happens for more than 1000 ns, we will also
  // detect that, and report it.
  channel.start-reading --max-ns=5_000_000 --min-ns=1000

  REPETITIONS ::= 90
  REPETITIONS.repeat:
    port1.out.write data

  received := channel.wait-for-data
  // For each data-transmission, we expect to see a long period of 0, followed by the
  // 0xFF byte which should be short (3250 ns).
  // If we ever receive a signal 1 that takes longer than 3500 ns, then we have
  // detected a gap in the transmission.
  expect-equals (2 * REPETITIONS) received.size

  received.do: | level p ns-duration |
    if level == 0: continue.do
    // Expect short high signals.
    expect ns-duration < 3500
