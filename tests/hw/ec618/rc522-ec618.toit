// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 SPI bring-up test against a real MFRC522 (RC522) RFID reader.

Standalone (no ESP32 helper: SPI0's CLK/MISO pads ARE the UART2 control
lane, so no lane is available — and none is needed). The reader hangs on
SPI0 with its RST on PAD16 (pulled down externally, so it sits in hard
power-down except while this test runs). Checks:

- version register reads an MFRC522 id (0x91/0x92; this unit: 0x92);
- FIFO write/read-back loopback, 64 bytes (the FIFO depth), several
  patterns — exercises MOSI and MISO with real data both ways;
- the same loopback as BURST transfers: one 65-byte transfer per
  direction, which crosses the library's >=64-byte threshold and takes
  the asynchronous DMA path (transfer-start/finish, completion by event)
  on both a write and a full-duplex read;
- soft power-down bit sets and clears on wake;
- the reader is left in hard power-down (RST low) so it cannot disturb
  the I2C1/UART2 tests that share these nets.

Wiring: RC522 SDA(=CS)=PAD23, MOSI=PAD24, MISO=PAD25, SCK=PAD26,
        RST=PAD16 (+pull-down), VCC=3.3V rail.

Run via the mini-jag tester:

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/rc522-ec618.toit
*/

import ec618 show Ec618
import gpio
import spi

RST-PAD ::= 16
CS-PAD ::= 23
MOSI-PAD ::= 24
MISO-PAD ::= 25
SCK-PAD ::= 26

REG-COMMAND ::= 0x01
REG-FIFO-DATA ::= 0x09
REG-FIFO-LEVEL ::= 0x0a
REG-VERSION ::= 0x37
COMMAND-IDLE ::= 0x00
FIFO-FLUSH ::= 0b1000_0000
POWER-DOWN-BIT ::= 0b0001_0000

failures := []

main:
  rst := gpio.Pin RST-PAD --output --value=1
  sleep --ms=50  // Crystal start-up out of hard power-down.

  bus := Ec618.spi0  // MOSI=PAD24, MISO=PAD25, CLK=PAD26.
  device := bus.device --cs=(Ec618.pad CS-PAD) --frequency=1_000_000

  version := read-reg device REG-VERSION
  print "rc522-ec618: version 0x$(%02x version)"
  check (version == 0x91 or version == 0x92) "version-mfrc522"

  // FIFO loopbacks: full 64-byte FIFO, several patterns.
  3.repeat: | round/int |
    write-reg device REG-COMMAND COMMAND-IDLE
    write-reg device REG-FIFO-LEVEL FIFO-FLUSH
    pattern := ByteArray 64: (it * 31 + 7 + round * 13) & 0xff
    pattern.size.repeat: write-reg device REG-FIFO-DATA pattern[it]
    level := read-reg device REG-FIFO-LEVEL
    got := ByteArray pattern.size: read-reg device REG-FIFO-DATA
    drained := read-reg device REG-FIFO-LEVEL
    ok := level == 64 and got == pattern and drained == 0
    print "rc522-ec618: fifo round $round $(ok ? "ok" : "FAIL") (level=$level drained=$drained match=$(got == pattern))"
    if not ok: failures.add "fifo-$round"

  // Burst loopbacks: one 65-byte transfer per direction — crosses the
  // library's >=64-byte threshold, so these run on the asynchronous DMA
  // path (transfer-start, event wait, transfer-finish). The read is a
  // full-duplex burst, exercising the driver's copy-back.
  3.repeat: | round/int |
    write-reg device REG-COMMAND COMMAND-IDLE
    write-reg device REG-FIFO-LEVEL FIFO-FLUSH
    pattern := ByteArray 64: (it * 17 + 3 + round * 29) & 0xff
    write-fifo-burst device pattern
    level := read-reg device REG-FIFO-LEVEL
    got := read-fifo-burst device pattern.size
    drained := read-reg device REG-FIFO-LEVEL
    ok := level == 64 and got == pattern and drained == 0
    print "rc522-ec618: burst round $round $(ok ? "ok" : "FAIL") (level=$level drained=$drained match=$(got == pattern))"
    if not ok: failures.add "burst-$round"

  // Soft power-down: the bit must set, and clear again on wake.
  write-reg device REG-COMMAND POWER-DOWN-BIT
  sleep --ms=5
  down := (read-reg device REG-COMMAND) & POWER-DOWN-BIT != 0
  check down "soft-power-down-sets"
  write-reg device REG-COMMAND COMMAND-IDLE
  sleep --ms=5
  up := (read-reg device REG-COMMAND) & POWER-DOWN-BIT == 0
  check up "soft-power-down-clears"

  // Read the version once more after the power cycle dance.
  check ((read-reg device REG-VERSION) == version) "version-stable"

  device.close
  bus.close
  rst.set 0  // Hard power-down: quiet pins for the shared nets.
  rst.close

  if not failures.is-empty:
    print "rc522-ec618: FAIL $failures"
    throw "RC522 SPI test failed: $failures"
  print "rc522-ec618: PASS"

check ok/bool label/string -> none:
  print "rc522-ec618: $label $(ok ? "ok" : "FAIL")"
  if not ok: failures.add label

read-reg device/spi.Device register/int -> int:
  data := ByteArray 2
  data[0] = (register << 1) | 0x80
  device.transfer data --read
  return data[1]

write-reg device/spi.Device register/int value/int -> none:
  device.transfer #[(register << 1) & 0x7e, value]

// Writes all $bytes into a register in ONE transfer (the MFRC522 keeps
// the address for every following byte; for the FIFO register each byte
// enters the FIFO).
write-fifo-burst device/spi.Device bytes/ByteArray -> none:
  data := ByteArray bytes.size + 1
  data[0] = (REG-FIFO-DATA << 1) & 0x7e
  data.replace 1 bytes
  device.transfer data

// Reads $count FIFO bytes in ONE full-duplex transfer: every MOSI byte
// but the last repeats the read address, and each MISO byte from index 1
// on carries FIFO data (the MFRC522 burst-read convention).
read-fifo-burst device/spi.Device count/int -> ByteArray:
  data := ByteArray count + 1: (REG-FIFO-DATA << 1) | 0x80
  data[count] = 0
  device.transfer data --read
  return data[1..]
