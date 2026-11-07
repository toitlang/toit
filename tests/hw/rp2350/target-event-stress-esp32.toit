// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import expect show *
import gpio
import i2c
import spi
import uart
import .target-event-stress-shared as protocol
import .wiring as wiring

/** Runs the ESP32 controller side of target-event-stress-rp2350.toit. */
main:
  control := uart.Port --tx=wiring.ESP32-UART-TX-PIN --rx=wiring.ESP32-UART-RX-PIN
      --baud-rate=115_200
  event := gpio.Pin wiring.ESP32-EVENT-PIN --output --value=0
  try:
    with-timeout --ms=180_000:
      // Ignore any trailing control bytes from a previous fixture.
      while control.in.read-byte != protocol.HELLO: null
      protocol.PHASES.size.repeat: | phase/int |
        run-phase control event phase
      expect-equals protocol.FINISHED control.in.read-byte
  finally:
    event.close
    control.close
  print "target-event-stress-esp32: PASS concurrent I2C/SPI and GPIO stimulus"

run-phase control/uart.Port event/gpio.Pin phase/int -> none:
  settings := protocol.PHASES[phase]
  i2c-bus := i2c.Bus --sda=wiring.ESP32-I2C-CONTROLLER-SDA-PIN
      --scl=wiring.ESP32-I2C-CONTROLLER-SCL-PIN
      --frequency=settings[3]
      --pull-up
  try:
    i2c-device := i2c-bus.device protocol.I2C-ADDRESS --timeout-us=100_000
    try:
      spi-bus := spi.Bus --mosi=wiring.ESP32-SPI-CONTROLLER-MOSI-PIN
          --miso=wiring.ESP32-SPI-CONTROLLER-MISO-PIN
          --clock=wiring.ESP32-SPI-CONTROLLER-CLOCK-PIN
      try:
        spi-device := spi-bus.device --cs=wiring.ESP32-SPI-CONTROLLER-CS-PIN
            --frequency=settings[2]
            --mode=settings[0]
        try:
          control.out.write #[protocol.PHASE, phase] --flush
          expect-equals protocol.READY control.in.read-byte
          protocol.ROUNDS.repeat: | round/int |
            control.out.write #[protocol.ROUND, round] --flush
            expect-equals protocol.READY control.in.read-byte
            Task.group [
              ::
                bytes := protocol.pattern protocol.SPI-SIZE (protocol.seed phase round)
                spi-device.transfer bytes --read
                expect-equals (protocol.pattern protocol.SPI-SIZE 0x35) bytes,
              ::
                bytes := protocol.pattern protocol.I2C-SIZE (protocol.seed phase round)
                i2c-device.write-address #[protocol.I2C-REGISTER] bytes
                expect-equals bytes (i2c-device.read-reg protocol.I2C-REGISTER protocol.I2C-SIZE),
              :: event.set (round + 1) & 1,
            ]
            control.out.write #[protocol.DONE] --flush
            expect-equals protocol.READY control.in.read-byte
          print "target-event-stress-esp32: phase=$phase PASS"
        finally:
          spi-device.close
      finally:
        spi-bus.close
    finally:
      i2c-device.close
  finally:
    i2c-bus.close
