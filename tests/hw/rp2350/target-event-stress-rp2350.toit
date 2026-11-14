// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import expect show *
import gpio
import i2c
import monitor
import spi
import system
import uart
import .target-event-stress-shared as protocol
import .wiring as wiring

/**
Tests I2C and SPI targets, GPIO waits, UART coordination and GC concurrently.

Start target-event-stress-esp32.toit on the helper before activating this
  bring-up image. The lanes are disjoint; the SPI CS raw interrupt and ordinary
  GPIO wait share the bank interrupt and must coexist. This image must be
  confirmed before the test's startup delay.
*/
main:
  control := uart.Port --tx=wiring.RP2350-UART-TX-PIN --rx=wiring.RP2350-UART-RX-PIN
      --baud-rate=115_200
  event := gpio.Pin wiring.RP2350-EVENT-PIN --input --pull-down
  try:
    print "target-event-stress-rp2350: waiting 20 seconds for ESP32 peer"
    sleep --ms=20_000
    with-timeout --ms=120_000:
      control.out.write #[protocol.HELLO] --flush
      protocol.PHASES.size.repeat: | phase/int |
        run-phase control event phase
      control.out.write #[protocol.FINISHED] --flush
  finally:
    event.close
    control.close
  print "target-event-stress-rp2350: PASS I2C/SPI targets, GPIO, UART and GC"

run-phase control/uart.Port event/gpio.Pin phase/int -> none:
  expect-equals protocol.PHASE control.in.read-byte
  expect-equals phase control.in.read-byte
  settings := protocol.PHASES[phase]
  registers := i2c.RegisterTarget
      --sda=wiring.RP2350-I2C-TARGET-SDA-PIN
      --scl=wiring.RP2350-I2C-TARGET-SCL-PIN
      --address=protocol.I2C-ADDRESS
      --receive-buffer-size=256
      --pull-up
  try:
    target := spi.BufferTarget (protocol.pattern protocol.SPI-SIZE 0x35)
        --mosi=wiring.RP2350-SPI-TARGET-MOSI-PIN
        --miso=wiring.RP2350-SPI-TARGET-MISO-PIN
        --clock=wiring.RP2350-SPI-TARGET-CLOCK-PIN
        --cs=wiring.RP2350-SPI-TARGET-CS-PIN
        --mode=settings[0]
        --dma=settings[1]
        --buffer-size=protocol.SPI-SIZE
        --receive-queue-depth=4
    try:
      control.out.write #[protocol.READY] --flush
      protocol.ROUNDS.repeat: | round/int |
        expect-equals protocol.ROUND control.in.read-byte
        expect-equals round control.in.read-byte
        armed := monitor.Channel 1
        Task.group [
          ::
            received := target.receive
            expect-equals (protocol.pattern protocol.SPI-SIZE (protocol.seed phase round)) received,
          ::
            armed.send null
            event.wait-for (round + 1) & 1,
          ::
            armed.receive
            // Let the GPIO waiter arm before allowing the peer to drive it.
            sleep --ms=1
            control.out.write #[protocol.READY] --flush,
          :: garbage-collect,
        ]
        expect-equals protocol.DONE control.in.read-byte
        expect-equals (protocol.pattern protocol.I2C-SIZE (protocol.seed phase round))
            (registers.read protocol.I2C-REGISTER protocol.I2C-SIZE)
        expect-equals 0 registers.dropped-write-count
        expect-equals 0 target.dropped-receive-count
        control.out.write #[protocol.READY] --flush
      print "target-event-stress-rp2350: phase=$phase mode=$(settings[0]) dma=$(settings[1]) PASS"
    finally:
      target.close
  finally:
    registers.close

garbage-collect -> none:
  retained := List 16: ByteArray 257 --initial=it
  16.repeat:
    system.process-stats --gc
    retained.size.repeat: | index/int |
      expect-equals index retained[index][256]
    sleep --ms=1
