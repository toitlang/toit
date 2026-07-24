// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import spi

/**
ESP32-side RC522 wiring probe — validates the breadboard hookup before
  the EC618 SPI bring-up uses the reader.

Wakes the RC522 out of hard power-down (RST on the PAD16/IO23 net),
  reads the version register (0x37: 0x91 = v1, 0x92 = v2, others are
  usually clones — report, don't judge) and runs a FIFO write/read-back
  loopback, exercising MOSI and MISO with real data. Then drops RST so
  the reader goes back to its quiet power-down state.

Wiring (shared nets with the EC618's SPI0 pads 23/24/25/26):
  RC522 SDA(=CS) - IO33 | MOSI - IO22 | MISO - IO14 | SCK - IO27
  RST - IO23 (with a pull-down) | VCC - 3.3 V | GND - GND

Run via Jaguar:

```
  jag run tests/hw/ec618/rc522-probe-esp32.toit --device <esp32>
```
*/

RST ::= 23
CS ::= 33
MOSI ::= 22
MISO ::= 14
SCK ::= 27

REG-FIFO-DATA ::= 0x09
REG-FIFO-LEVEL ::= 0x0a
REG-COMMAND ::= 0x01
REG-VERSION ::= 0x37
COMMAND-IDLE ::= 0x00
COMMAND-FLUSH ::= 0b0001_0000  // FIFOLevelReg flush bit.

read-reg device/spi.Device register/int -> int:
  data := ByteArray 2
  data[0] = (register << 1) | 0x80
  device.transfer data --read
  return data[1]

write-reg device/spi.Device register/int value/int -> none:
  device.transfer #[(register << 1) & 0x7e, value]

main:
  rst := gpio.Pin RST --output --value=1
  sleep --ms=50  // Oscillator start-up out of hard power-down.

  bus := spi.Bus --clock=(gpio.Pin SCK) --mosi=(gpio.Pin MOSI) --miso=(gpio.Pin MISO)
  device := bus.device --cs=(gpio.Pin CS) --frequency=1_000_000

  version := read-reg device REG-VERSION
  kind/string := "unknown/clone"
  if version == 0x91: kind = "MFRC522 v1"
  if version == 0x92: kind = "MFRC522 v2"
  print "rc522-probe: version 0x$(%02x version) -> $kind"
  if version == 0x00 or version == 0xff:
    print "rc522-probe: FAIL bus dead (all-$(version == 0 ? "zeros" : "ones") — check wiring)"
    rst.set 0
    return

  // FIFO loopback: flush, write a pattern, check the level, read it back.
  write-reg device REG-COMMAND COMMAND-IDLE
  write-reg device REG-FIFO-LEVEL COMMAND-FLUSH
  pattern := ByteArray 16: (it * 31 + 7) & 0xff
  pattern.size.repeat: write-reg device REG-FIFO-DATA pattern[it]
  level := read-reg device REG-FIFO-LEVEL
  got := ByteArray pattern.size: read-reg device REG-FIFO-DATA
  ok := level == pattern.size and got == pattern
  print "rc522-probe: fifo loopback $(ok ? "ok" : "FAIL") (level=$level, data $(got == pattern ? "match" : "MISMATCH"))"

  rst.set 0  // Back to hard power-down: quiet pins, microamps.
  print "rc522-probe: $(ok and version != 0 ? "PASS" : "FAIL"); reader powered down"
