// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import spi

import .wiring as wiring
import ..shared.rc522 as rc522

/**
ESP32-side RC522 wiring probe — validates the breadboard hookup before
  the EC618 SPI bring-up uses the reader.

Wakes the RC522 out of hard power-down (RST on the PAD16/IO23 net),
  reads the version register (0x37: 0x91 = v1, 0x92 = v2, others are
  usually clones — report, don't judge) and runs a FIFO write/read-back
  loopback, exercising MOSI and MISO with real data. Then drops RST so
  the reader goes back to its quiet power-down state.

*/

main:
  rst := gpio.Pin wiring.ESP32-RC522-RST-PIN --output --value=1
  sleep --ms=50  // Oscillator start-up out of hard power-down.

  bus := spi.Bus
      --clock=wiring.ESP32-SPI0-CLK-PIN
      --mosi=wiring.ESP32-SPI0-MOSI-PIN
      --miso=wiring.ESP32-SPI0-MISO-PIN
  device := bus.device --cs=wiring.ESP32-SPI0-CS-PIN --frequency=1_000_000

  passed := false
  try:
    version := rc522.read-reg device rc522.REG-VERSION
    kind/string := "unknown/clone"
    if version == 0x91: kind = "MFRC522 v1"
    if version == 0x92: kind = "MFRC522 v2"
    print "rc522-probe: version 0x$(%02x version) -> $kind"
    if version == 0x00 or version == 0xff:
      print "rc522-probe: FAIL bus dead (all-$(version == 0 ? "zeros" : "ones") — check wiring)"
    else:
      // FIFO loopback: flush, write a pattern, check the level, read it back.
      rc522.write-reg device rc522.REG-COMMAND rc522.COMMAND-IDLE
      rc522.write-reg device rc522.REG-FIFO-LEVEL rc522.FIFO-FLUSH
      pattern := ByteArray 16: (it * 31 + 7) & 0xff
      rc522.write-fifo device pattern
      level := rc522.read-reg device rc522.REG-FIFO-LEVEL
      got := rc522.read-fifo device pattern.size
      passed = level == pattern.size and got == pattern
      print "rc522-probe: fifo loopback $(passed ? "ok" : "FAIL") (level=$level, data $(got == pattern ? "match" : "MISMATCH"))"
  finally:
    device.close
    bus.close
    rst.set 0
    rst.close

  if not passed: throw "RC522 probe failed"
  print "rc522-probe: PASS; reader powered down"
