// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests reading and writing of the UART baud rate.

For the setup see the comment near $Variant.uart-flush-in1.
*/

import expect show *
import gpio
import uart

import .test
import .variants

// Not that RX1 goes to TX2 and TX1 goes to RX2.
RX1 ::= Variant.CURRENT.uart-baud-rate-in2
TX1 ::= Variant.CURRENT.uart-baud-rate-out1

RX2 ::= Variant.CURRENT.uart-baud-rate-in1
TX2 ::= Variant.CURRENT.uart-baud-rate-out2


main:
  run-test: test

test:
  succeeded := false
  pin-rx1 := gpio.Pin RX1
  pin-tx1 := gpio.Pin TX1
  pin-rx2 := gpio.Pin RX2
  pin-tx2 := gpio.Pin TX2
  for i := 0; i < 2; i++:
    port1 := uart.Port
        --rx=pin-rx1
        --tx=pin-tx1
        --baud-rate=1200

    port2 := uart.Port
        --rx=pin-rx2
        --tx=pin-tx2
        --baud-rate=1200

    TEST-STR ::= "toit toit toit toit"
    done := false
    before := 0
    after := 0
    task::
      print "writing to slow port"
      port1.out.write TEST-STR
      before = Time.monotonic-us
      port1.out.flush
      after = Time.monotonic-us
      print "flush took $(after - before) us"
      done = true

    woken := []
    while not done:
      woken.add Time.monotonic-us
      sleep --ms=10

    // While we were waiting for port1 to flush we were woken several times.
    expect woken.size > 5

    // We make sure that the medium entry was while port1 was flushing.
    expect before < woken[woken.size / 2] < after

    diff := after - before
    expect diff > 50_000

    // When the baud rate is too low we seem to have problems reading... :(
    // Generally, it's enough to do a second round.
    // https://github.com/espressif/esp-idf/issues/9397
    data := port2.in.read
    // expect_equals TEST_STR data.to_string_non_throwing
    if TEST-STR != data.to-string-non-throwing:
      print "***********************************  NOT EQUAL"
    else:
      succeeded = true
      break

    port1.close
    port2.close

  expect succeeded

  pin-rx1.close
  pin-tx1.close
  pin-rx2.close
  pin-tx2.close
