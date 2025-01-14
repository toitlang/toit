// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the '--keep-cs-active' flag of the SPI transfer.

For the setup see the comment near $Variant.spi-keep-active-cs-pin.
*/

import expect show *
import spi
import gpio
import monitor

import .test
import .variants

CS ::= Variant.CURRENT.spi-keep-active-cs-pin
MISO ::= Variant.CURRENT.unconnected-pin1
MOSI ::= Variant.CURRENT.unconnected-pin2
SCK ::= Variant.CURRENT.unconnected-pin3

IN-CS ::= Variant.CURRENT.spi-keep-active-in-cs-pin

class DebugChannel:
  channel_ := monitor.Channel 1
  receive:
    val := channel_.receive
    print "=> $val"
    return val

  send x:
    channel_.send x

main:
  run-test: test

test:
  bus := spi.Bus
      --clock=gpio.Pin SCK
      --miso=gpio.Pin MISO
      --mosi=gpio.Pin MOSI

  device := bus.device
      --cs=gpio.Pin CS
      --frequency=10_000_000

  in := gpio.Pin IN-CS --input

  2.repeat: | test-iteration/int |
    channel-to-task := DebugChannel
    channel-from-task := DebugChannel

    task::
      device.with-reserved-bus:
        expect-equals "keep_active" channel-to-task.receive
        device.transfer #[1, 2, 3] --keep-cs-active
        channel-from-task.send "cs_is_active"
        expect-equals "transfer_without_active" channel-to-task.receive
        device.transfer #[0]
        channel-from-task.send "cs_is_inactive"
        if test-iteration == 1:
          expect-equals "active again" channel-to-task.receive
          device.transfer #[1, 2, 3] --keep-cs-active
          channel-from-task.send "cs_is_active again"
        expect-equals "done" channel-to-task.receive
      channel-from-task.send "bus_is_free"


    expect-equals 1 in.get
    channel-to-task.send "keep_active"
    expect-equals "cs_is_active" channel-from-task.receive
    expect-equals 0 in.get
    channel-to-task.send "transfer_without_active"
    expect-equals "cs_is_inactive" channel-from-task.receive
    expect-equals 1 in.get
    if test-iteration == 1:
      channel-to-task.send "active again"
      expect-equals "cs_is_active again" channel-from-task.receive
      expect-equals 0 in.get
    channel-to-task.send "done"
    // When the bus is released, the CS pin should be low.
    expect-equals "bus_is_free" channel-from-task.receive
    // TODO(florian): reenable this test once https://github.com/espressif/esp-idf/issues/9390 is fixed.
    // expect_equals 1 in.get

  in.close
  device.close
  bus.close
