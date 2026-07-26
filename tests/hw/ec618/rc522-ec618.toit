// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import gpio
import spi

import .wiring as wiring
import ..shared.rc522 as rc522

/**
EC618 SPI bring-up test against a real MFRC522 (RC522) RFID reader.

Standalone (no ESP32 helper: SPI0's CLK/MISO pads ARE the UART2 control lane, so no lane is available — and none is needed). The reader hangs on SPI0 with its RST on PAD16 (pulled down externally, so it sits in hard power-down except while this test runs). Checks:

- version register reads an MFRC522 id (0x91/0x92; this unit: 0x92);
- FIFO write/read-back loopback, 64 bytes (the FIFO depth), several patterns — exercises MOSI and MISO with real data both ways;
- the same loopback as BURST transfers: one 65-byte transfer per direction, which crosses the library's >=64-byte threshold and takes the asynchronous DMA path (transfer-start/finish, completion by event) on both a write and a full-duplex read;
- soft power-down bit sets and clears on wake;
- the reader is left in hard power-down (RST low) so it cannot disturb the I2C1/UART2 tests that share these nets.
*/

POWER-DOWN-BIT ::= 0b0001_0000

failures := []

main args:
  mosi := Ec618.pad wiring.EC618-SPI0-MOSI-PAD
  miso := Ec618.pad wiring.EC618-SPI0-MISO-PAD
  clock := Ec618.pad wiring.EC618-SPI0-CLK-PAD
  bus := spi.Bus --mosi=mosi --miso=miso --clock=clock

  // Reuse the exact same Pin objects so the GPIO pad pool cannot be what
  // rejects this second bus. The SPI controller itself must be exclusive
  // across containers, and both explicit and forced teardown must return it.
  duplicate/spi.Bus? := null
  duplicate-error := catch:
    duplicate = spi.Bus --mosi=mosi --miso=miso --clock=clock
  if duplicate: duplicate.close
  check (duplicate-error == "ALREADY_IN_USE") "controller-exclusive"

  if not args.is-empty and args[0] == "leak":
    print "rc522-ec618: leaving SPI0 open for forced-teardown phase"
    return

  bus.close
  bus = spi.Bus --mosi=mosi --miso=miso --clock=clock
  check true "controller-reacquired-after-close"

  rst := gpio.Pin wiring.EC618-RC522-RST-PAD --output --value=1
  sleep --ms=50  // Crystal start-up out of hard power-down.

  cs := Ec618.pad wiring.EC618-SPI0-CS-PAD
  device := bus.device --cs=cs --frequency=1_000_000

  version := rc522.read-reg device rc522.REG-VERSION
  print "rc522-ec618: version 0x$(%02x version)"
  check (version == 0x91 or version == 0x92) "version-mfrc522"

  // FIFO loopbacks: full 64-byte FIFO, several patterns.
  3.repeat: | round/int |
    rc522.write-reg device rc522.REG-COMMAND rc522.COMMAND-IDLE
    rc522.write-reg device rc522.REG-FIFO-LEVEL rc522.FIFO-FLUSH
    pattern := ByteArray 64: (it * 31 + 7 + round * 13) & 0xff
    rc522.write-fifo device pattern
    level := rc522.read-reg device rc522.REG-FIFO-LEVEL
    got := rc522.read-fifo device pattern.size
    drained := rc522.read-reg device rc522.REG-FIFO-LEVEL
    ok := level == 64 and got == pattern and drained == 0
    print "rc522-ec618: fifo round $round $(ok ? "ok" : "FAIL") (level=$level drained=$drained match=$(got == pattern))"
    if not ok: failures.add "fifo-$round"

  // Burst loopbacks: one 65-byte transfer per direction — crosses the
  // library's >=64-byte threshold, so these run on the asynchronous DMA
  // path (transfer-start, event wait, transfer-finish). The read is a
  // full-duplex burst, exercising the driver's copy-back.
  3.repeat: | round/int |
    rc522.write-reg device rc522.REG-COMMAND rc522.COMMAND-IDLE
    rc522.write-reg device rc522.REG-FIFO-LEVEL rc522.FIFO-FLUSH
    pattern := ByteArray 64: (it * 17 + 3 + round * 29) & 0xff
    rc522.write-fifo-burst device pattern
    level := rc522.read-reg device rc522.REG-FIFO-LEVEL
    got := rc522.read-fifo-burst device pattern.size
    drained := rc522.read-reg device rc522.REG-FIFO-LEVEL
    ok := level == 64 and got == pattern and drained == 0
    print "rc522-ec618: burst round $round $(ok ? "ok" : "FAIL") (level=$level drained=$drained match=$(got == pattern))"
    if not ok: failures.add "burst-$round"

  // Async full-duplex copy-back must honor a nonzero transfer range without
  // touching prefix/suffix sentinels in the caller's ByteArray.
  rc522.write-reg device rc522.REG-COMMAND rc522.COMMAND-IDLE
  rc522.write-reg device rc522.REG-FIFO-LEVEL rc522.FIFO-FLUSH
  offset-pattern := ByteArray 64: (it * 23 + 11) & 0xff
  rc522.write-fifo-burst device offset-pattern
  ranged := ByteArray 69 --initial=0xa5
  65.repeat: ranged[2 + it] = (rc522.REG-FIFO-DATA << 1) | 0x80
  ranged[66] = 0
  device.transfer ranged --from=2 --to=67 --read
  check (ranged[..2] == #[0xa5, 0xa5]) "async-offset-prefix-intact"
  check (ranged[3..67] == offset-pattern) "async-offset-copy-back"
  check (ranged[67..] == #[0xa5, 0xa5]) "async-offset-suffix-intact"

  // Soft power-down: the bit must set, and clear again on wake.
  rc522.write-reg device rc522.REG-COMMAND POWER-DOWN-BIT
  sleep --ms=5
  down := (rc522.read-reg device rc522.REG-COMMAND) & POWER-DOWN-BIT != 0
  check down "soft-power-down-sets"
  rc522.write-reg device rc522.REG-COMMAND rc522.COMMAND-IDLE
  sleep --ms=5
  up := (rc522.read-reg device rc522.REG-COMMAND) & POWER-DOWN-BIT == 0
  check up "soft-power-down-clears"

  // Read the version once more after the power cycle dance.
  check ((rc522.read-reg device rc522.REG-VERSION) == version) "version-stable"

  // A user deadline must cancel the asynchronous DMA transfer, stop the
  // engine before its native buffer is released, and leave the controller
  // reusable. At 1 MHz this transfer would take over 250 ms.
  cancellation := null
  cancellation-us := Duration.of:
    cancellation = catch:
      with-timeout --ms=20:
        device.transfer (ByteArray 0x8000)
  check (cancellation == "DEADLINE_EXCEEDED") "dma-cancellation"
  check (cancellation-us.in-ms < 150) "dma-cancellation-prompt"

  // The cancelled stream intentionally wrote arbitrary bytes to the reader.
  // Reset the slave protocol, then prove the same SPI device still works.
  rst.set 0
  sleep --ms=5
  rst.set 1
  sleep --ms=50
  check ((rc522.read-reg device rc522.REG-VERSION) == version) "reuse-after-cancel"

  device.close

  // The EC618 byte-frame engine can pack command+address phases exactly
  // whenever their combined width is byte-aligned. Exercise two 4-bit
  // phases as the RC522 register byte, including an actual command value 0.
  prefixed := bus.device
      --cs=cs
      --frequency=1_000_000
      --command-bits=4
      --address-bits=4
  version-byte := ByteArray 1
  version-command := (rc522.REG-VERSION << 1) | 0x80
  prefixed.transfer version-byte
      --read
      --command=(version-command >> 4)
      --address=(version-command & 0xf)
  check (version-byte[0] == version) "command-address-prefix-read"
  prefixed.transfer #[rc522.COMMAND-IDLE]
      --command=0
      --address=((rc522.REG-COMMAND << 1) & 0xf)
  command-byte := ByteArray 1
  command-read := (rc522.REG-COMMAND << 1) | 0x80
  prefixed.transfer command-byte
      --read
      --command=(command-read >> 4)
      --address=(command-read & 0xf)
  check (command-byte[0] == rc522.COMMAND-IDLE) "zero-command-prefix-write"
  prefixed.close

  invalid-prefix-error := catch:
    bus.device --cs=cs --frequency=1_000_000 --command-bits=1
  check (invalid-prefix-error == "INVALID_ARGUMENT") "unaligned-prefix-rejected"

  bus.close
  cs.close
  rst.set 0  // Hard power-down: quiet pins for the shared nets.
  rst.close

  if not failures.is-empty:
    print "rc522-ec618: FAIL $failures"
    throw "RC522 SPI test failed: $failures"
  print "rc522-ec618: PASS"

check ok/bool label/string -> none:
  print "rc522-ec618: $label $(ok ? "ok" : "FAIL")"
  if not ok: failures.add label
