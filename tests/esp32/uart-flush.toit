// Copyright (C) 2022 Toitware ApS.
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

RX1 := 18
TX1 := 26
RX2 := 33
TX2 := 19

main:
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
