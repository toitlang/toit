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
import writer

RX1 := 16
TX1 := 17
RX2 := 27
TX2 := 26

main:
  succeeded := false
  pin_rx1 := gpio.Pin RX1
  pin_tx1 := gpio.Pin TX1
  pin_rx2 := gpio.Pin RX2
  pin_tx2 := gpio.Pin TX2
  for i := 0; i < 2; i++:
    port1 := uart.Port
        --rx=pin_rx1
        --tx=pin_tx1
        --baud_rate=1200

    port2 := uart.Port
        --rx=pin_rx2
        --tx=pin_tx2
        --baud_rate=1200

    print port1.baud_rate
    TEST_STR ::= "toit toit toit toit"
    done := false
    before := 0
    after := 0
    task::
      print "writing to slow port"
      writer := writer.Writer port1
      writer.write TEST_STR
      before = Time.monotonic_us
      port1.flush
      after = Time.monotonic_us
      print "writing finished"
      done = true

    woken := []
    while not done:
      woken.add Time.monotonic_us
      sleep --ms=10

    // While we were waiting for port1 to flush we were woken several times.
    expect woken.size > 5

    // We make sure that the medium entry was while port1 was flushing.
    expect before < woken[woken.size / 2] < after

    diff := after - before
    expect diff > 50_000

    // When the baud rate is too low we seem to have problems reading... :(
    // Generally, it's enough to do a second round.
    data := port2.read
    print "$data.size"
    // expect_equals TEST_STR data.to_string_non_throwing
    if TEST_STR != data.to_string_non_throwing:
      print "***********************************  NOT EQUAL"
    else:
      succeeded = true
      break

    port1.close
    port2.close

  expect succeeded

  pin_rx1.close
  pin_tx1.close
  pin_rx2.close
  pin_tx2.close

