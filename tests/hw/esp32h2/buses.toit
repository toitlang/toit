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

IS-H2 ::= system.architecture == system.ARCHITECTURE-ESP32H2
CS ::= IS-H2 ? 1 : 14
CLK ::= IS-H2 ? 4 : 32
MOSI ::= IS-H2 ? 3 : 26
MISO ::= IS-H2 ? 0 : 12

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 37 + seed) & 255

main:
  port := uart.Port
      --rx=(IS-H2 ? H2-RX : HELPER-RX)
      --tx=(IS-H2 ? H2-TX : HELPER-TX)
      --baud-rate=115200
  if IS-H2: sleep --ms=1500
  try:
    [true, false].do: | h2-controller |
      controller := h2-controller == IS-H2
      4.repeat: | mode |
        sizes := h2-controller ? [16, 64] : [1, 3, 16, 1024]
        sizes.do: | size |
          spi-case port controller mode size (not h2-controller)
      print "SPI role $(controller ? "controller" : "target") passed"
    [true, false].do: | h2-controller |
      controller := h2-controller == IS-H2
      [50_000, 100_000].do: | frequency |
        [1, 16, 255, 1024].do: | size |
          i2c-case port controller frequency size
      print "I2C role $(controller ? "controller" : "target") passed"
    [true, false].do: | h2-transmits |
      rmt-case port (h2-transmits == IS-H2)
  finally:
    port.close
  print "All tests done"

spi-case port/uart.Port controller/bool mode/int size/int dma/bool:
  tx := pattern size (controller ? 17 : 93)
  expected := pattern size (controller ? 93 : 17)
  if controller:
    bus := spi.Bus --clock=CLK --mosi=MOSI --miso=MISO
    device := bus.device --cs=CS --frequency=400_000 --mode=mode --cs-setup-cycles=2
    try:
      port.out.write-byte 1
      expect-equals 2 port.in.read-byte
      device.transfer tx --read
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
      expect-equals expected received
      port.out.write-byte 3
      expect-equals 4 port.in.read-byte
    finally:
      target.close
    port.out.write-byte 5
  print "SPI mode=$mode bytes=$size dma=$dma passed"

i2c-case port/uart.Port controller/bool frequency/int size/int:
  tx := pattern size 47
  response := pattern 32 123
  if controller:
    bus := i2c.Bus --sda=CS --scl=CLK
    device := bus.device 0x42 --frequency=frequency
    try:
      port.out.write-byte 1
      expect-equals 2 port.in.read-byte
      if size == 255:
        absent := bus.device 0x43 --frequency=frequency
        expect-throw "I2C_NACK": absent.write-read tx response.size
        absent.close
      expect-equals response (device.write-read tx response.size)
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
      expect-equals tx target.read
      expect-equals 3 port.in.read-byte
    finally:
      target.close
    port.out.write-byte 4
  print "I2C frequency=$frequency write=$size read=32 passed"

rmt-case port/uart.Port transmit/bool:
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
    expect-equals 12 signals.size
    11.repeat:
      expect-equals (1 - it % 2) (signals.level it)
      expect ((signals.period it) - (50 + it * 10)).abs <= 3
    expect-equals 0 (signals.period 11)
    input.close
    port.out.write-byte 3
    expect-equals 4 port.in.read-byte
  print "RMT $(transmit ? "transmit" : "receive") passed"
