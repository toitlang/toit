// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2c
import rmt
import spi
import system
import uart
import .wiring
import .session

IS-H2 ::= system.architecture == system.ARCHITECTURE-ESP32H2
CS ::= IS-H2 ? 1 : 14
CLK ::= IS-H2 ? 4 : 32
MOSI ::= IS-H2 ? 3 : 26
MISO ::= IS-H2 ? 0 : 12

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 37 + seed) & 255

main:
  session := Session
  port := session.port
  try:
    [true, false].do: | h2-controller |
      controller := h2-controller == IS-H2
      4.repeat: | mode |
        sizes := h2-controller ? [16, 64] : [1, 3, 16, 1024]
        sizes.do: | size |
          session.run-case "SPI h2-controller=$h2-controller mode=$mode size=$size":
            observed := spi-case port controller mode size (not h2-controller)
            peer-observed := session.observation observed
            if not IS-H2:
              expect-equals (pattern size (h2-controller ? 93 : 17)) peer-observed
      print "SPI role $(controller ? "controller" : "target") passed"
    [true, false].do: | h2-controller |
      controller := h2-controller == IS-H2
      [50_000, 100_000].do: | frequency |
        [1, 16, 255, 1024].do: | size |
          session.run-case "I2C h2-controller=$h2-controller frequency=$frequency size=$size":
            observed := i2c-case port controller frequency size
            peer-observed := session.observation observed
            if not IS-H2:
              expected := h2-controller ? (pattern 32 123) : (pattern size 47)
              expect-equals expected peer-observed
      print "I2C role $(controller ? "controller" : "target") passed"
    [true, false].do: | h2-transmits |
      session.run-case "RMT h2-transmits=$h2-transmits":
        observed := rmt-case port (h2-transmits == IS-H2)
        peer-observed := session.observation observed
        if not IS-H2 and not h2-transmits: verify-rmt peer-observed
    session.finish
  finally:
    session.close

spi-case port/uart.Port controller/bool mode/int size/int dma/bool:
  tx := pattern size (controller ? 17 : 93)
  expected := pattern size (controller ? 93 : 17)
  observed := null
  if controller:
    bus := spi.Bus --clock=CLK --mosi=MOSI --miso=MISO
    device := bus.device --cs=CS --frequency=400_000 --mode=mode --cs-setup-cycles=2
    try:
      port.out.write-byte 1
      expect-equals 2 port.in.read-byte
      device.transfer tx --read
      observed = tx
      expect-equals expected tx
      expect-equals 3 port.in.read-byte
    finally:
      device.close
      bus.close
    port.out.write-byte 4
    expect-equals 5 port.in.read-byte
  else:
    expect-equals 1 port.in.read-byte
    target := spi.Target --clock=CLK --cs=CS --mosi=MOSI --miso=MISO
        --mode=mode
        --max-transfer-size=size
        --dma=dma
    try:
      received := target.transfer tx --receive-size=size --when-armed=:
        port.out.write-byte 2
        port.out.flush
      observed = received
      expect-equals expected received
      port.out.write-byte 3
      expect-equals 4 port.in.read-byte
    finally:
      target.close
    port.out.write-byte 5
  return observed

i2c-case port/uart.Port controller/bool frequency/int size/int:
  tx := pattern size 47
  response := pattern 32 123
  observed := null
  if controller:
    // Let the target establish idle pull-ups before attaching the controller.
    // Otherwise a pin transition left by SPI can look like an I2C START.
    port.out.write-byte 1
    expect-equals 2 port.in.read-byte
    bus := i2c.Bus --sda=CS --scl=CLK
    device := bus.device 0x42 --frequency=frequency
    try:
      if size == 255:
        absent := bus.device 0x43 --frequency=frequency
        expect-throw "I2C_NACK": absent.write-read tx response.size
        absent.close
      observed = device.write-read tx response.size
      expect-equals response observed
      port.out.write-byte 3
      expect-equals 4 port.in.read-byte
    finally:
      device.close
      bus.close
  else:
    expect-equals 1 port.in.read-byte
    target := i2c.Target --sda=CS --scl=CLK --address=0x42
        --send-buffer-size=64
        --receive-buffer-size=2048
        --pull-up
    try:
      target.write response
      port.out.write-byte 2
      observed = target.read
      expect-equals tx observed
      expect-equals 3 port.in.read-byte
    finally:
      target.close
    port.out.write-byte 4
  return observed

rmt-case port/uart.Port transmit/bool:
  observed := null
  if transmit:
    out := rmt.Out CS --resolution=1_000_000
    port.out.write-byte 1
    expect-equals 2 port.in.read-byte
    signals := rmt.Signals.alternating 11 --first-level=1: 50 + it * 10
    out.write signals --done-level=0
    expect-equals 3 port.in.read-byte
    out.close
    port.out.write-byte 4
  else:
    expect-equals 1 port.in.read-byte
    input := rmt.In CS --resolution=1_000_000
    input.start-reading --min-ns=1000 --max-ns=500_000
    port.out.write-byte 2
    signals := input.wait-for-data
    observed = List signals.size: [signals.level it, signals.period it]
    verify-rmt observed
    input.close
    port.out.write-byte 3
    expect-equals 4 port.in.read-byte
  return observed

verify-rmt observed/List:
  expect-equals 12 observed.size
  11.repeat:
    expect-equals (1 - it % 2) observed[it][0]
    expect (observed[it][1] - (50 + it * 10)).abs <= 3
  expect-equals 0 observed[11][1]
