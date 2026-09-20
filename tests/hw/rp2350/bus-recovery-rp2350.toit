// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-equals expect-throw
import i2c
import system
import uart

import .i2c-controller-rp2350 as controller
import .spi-contract-rp2350 as spi-contract

/**
Tests asynchronous controller cancellation and reuse on both RP2350 I2C buses.

Runs with i2c-target-esp32.toit. The peer holds SCL low until the RP2350's
  task deadline cancels the transfer, then supplies a response for the next
  transfer. Also runs the target-independent SPI cancellation contract after
  the peer releases its pins.
*/

main:
  control := uart.Port --tx=16 --rx=1 --baud-rate=115_200
  try:
    print "bus-recovery-rp2350: waiting 20 seconds for ESP32 peer"
    sleep --ms=20_000
    [0, 1].do:
      controller.test-controller-baseline control it
      test-cancellation control it
    controller.send-line control "QUIT"
    controller.expect-line control "BYE"
  finally:
    control.close
  spi-contract.main
  print "bus-recovery-rp2350: PASS"

test-cancellation control/uart.Port index/int:
  pins := controller.controller-pins index
  bus := i2c.Bus --sda=pins[0] --scl=pins[1] --frequency=100_000 --pull-up
  try:
    device := bus.device controller.ADDRESS --frequency=100_000 --timeout-us=100_000
    try:
      12.repeat:
        controller.send-line control "STUCK $index"
        controller.expect-line control "READY"
        try:
          // The task deadline must win over the native 100 ms timeout, and
          // retire the transfer before the same device is reused.
          expect-throw DEADLINE-EXCEEDED-ERROR:
            with-timeout --ms=5: device.write-read #[0x17] 32
        finally:
          controller.send-line control "RELEASE"
          controller.expect-line control "OK"
        system.process-stats --gc
        controller.arm control index 4
        expect-equals (controller.pattern 4 7)
            with-timeout --ms=2_000: device.read 4
      print "I2C$index: 12 task cancellations, GC, and recovery reads PASS"
    finally:
      device.close
  finally:
    bus.close
    controller.send-line control "CLOSE"
    controller.expect-line control "OK"
