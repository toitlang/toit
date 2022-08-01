// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the '--keep_cs_active' flag of the SPI transfer.

Setup:
Connect pin 18 and 15 with a 330 Ohm resistor. The resistor isn't
  strictly necessary but can prevent accidental short circuiting.

Make sure that pins 12, 13, and 14 are not connected to anything important. They
  are used as output.
*/

import expect show *
import spi
import gpio
import monitor


CS ::= 15
MISO ::= 12
MOSI ::= 13
SCK ::= 14

IN_CS /int ::= 18

class DebugChannel:
  channel_ := monitor.Channel 1
  receive:
    val := channel_.receive
    print "=> $val"
    return val

  send x:
    channel_.send x

main:
  bus := spi.Bus
      --clock=gpio.Pin SCK
      --miso=gpio.Pin MISO
      --mosi=gpio.Pin MOSI

  device := bus.device
      --cs=gpio.Pin CS
      --frequency=10_000_000

  in := gpio.Pin IN_CS --input

  2.repeat: | test_iteration/int |
    channel_to_task := DebugChannel
    channel_from_task := DebugChannel

    task::
      device.with_reserved_bus:
        expect_equals "keep_active" channel_to_task.receive
        device.transfer #[1, 2, 3] --keep_cs_active
        channel_from_task.send "cs_is_active"
        expect_equals "transfer_without_active" channel_to_task.receive
        device.transfer #[0]
        channel_from_task.send "cs_is_inactive"
        if test_iteration == 1:
          expect_equals "active again" channel_to_task.receive
          device.transfer #[1, 2, 3] --keep_cs_active
          channel_from_task.send "cs_is_active again"
        expect_equals "done" channel_to_task.receive
      channel_from_task.send "bus_is_free"


    expect_equals 1 in.get
    channel_to_task.send "keep_active"
    expect_equals "cs_is_active" channel_from_task.receive
    expect_equals 0 in.get
    channel_to_task.send "transfer_without_active"
    expect_equals "cs_is_inactive" channel_from_task.receive
    expect_equals 1 in.get
    if test_iteration == 1:
      channel_to_task.send "active again"
      expect_equals "cs_is_active again" channel_from_task.receive
      expect_equals 0 in.get
    channel_to_task.send "done"
    // When the bus is released, the CS pin should be low.
    expect_equals "bus_is_free" channel_from_task.receive
    // TODO(florian): reenable this test once https://github.com/espressif/esp-idf/issues/9390 is fixed.
    // expect_equals 1 in.get

  in.close
  device.close
  bus.close

  print "Test finished successfully"
