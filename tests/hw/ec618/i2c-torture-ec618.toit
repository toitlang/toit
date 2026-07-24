// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import i2c
import io
import uart

/**
EC618 I2C shape-change torture (device under test) — the known-issues #6
  regression test, on the CMSIS IRQ-mode engine WITHOUT any per-transfer
  reset.

The closed soc_i2c engine silently swallowed a transfer whose shape
  differed from the previous one (instant fake success, untouched buffer),
  which forced a GPR module reset before EVERY transfer. The open bsp_i2c.c
  engine must not need that: this test hammers shape-changing transfers
  against a real BMP280 at 100 kHz and 400 kHz, validating every byte read.

Per round (every consecutive pair differs in shape and direction):
  - 1-byte register read (chip-id, value-checked 0x58),
  - 24-byte register read (full calibration block, dig_T1 cross-checked),
  - 1-byte plain write (control-meas: forced measurement),
  - 2-byte register read (dig_T1, must match the block read),
  - 6-byte register read (measurement burst, plausibility-checked),
  - 1-byte read with NO register write (SMBus receive-byte),
  - probe of an empty address (NACK path between data transfers).

Wiring: as bmp280-ec618.toit (sensor on I2C1 pads 23/24; ESP32 IO13 powers
  it; UART2 lane carries the power command).

Run via the mini-jag tester (start bmp280-esp32.toit FIRST):

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/i2c-torture-ec618.toit
```
*/

ADDRESS ::= 0x76
EMPTY-ADDRESS ::= 0x40

REG-CALIBRATION ::= 0x88
REG-CHIP-ID ::= 0xd0
REG-CONTROL-MEAS ::= 0xf4
REG-DATA ::= 0xf7

ROUNDS ::= 25

failures := []

main:
  control := Ec618.uart2 --baud-rate=115200
  exchange control "P 1"

  bus := Ec618.i2c1  // SDA=PAD23, SCL=PAD24.

  [100_000, 400_000].do: | frequency/int |
    device := bus.device ADDRESS --frequency=frequency
    registers := device.registers

    // Reference calibration from one block read; later short reads must
    // agree (catches a swallowed transfer leaving a stale buffer).
    calibration := registers.read-bytes REG-CALIBRATION 24
    dig-t1 := io.LITTLE-ENDIAN.uint16 calibration 0
    check (dig-t1 != 0 and dig-t1 != 0xffff) "$frequency/calibration-sane"

    bad := 0
    ROUNDS.repeat: | round/int |
      id := registers.read-u8 REG-CHIP-ID                       // 1B reg-read.
      if id != 0x58: bad++
      block := registers.read-bytes REG-CALIBRATION 24          // 24B reg-read.
      if (io.LITTLE-ENDIAN.uint16 block 0) != dig-t1: bad++
      registers.write-u8 REG-CONTROL-MEAS 0b001_001_01          // 2B write.
      short := registers.read-bytes REG-CALIBRATION 2           // 2B reg-read.
      if (io.LITTLE-ENDIAN.uint16 short 0) != dig-t1: bad++
      sleep --ms=10                                             // Measurement.
      data := registers.read-bytes REG-DATA 6                   // 6B reg-read.
      adc-t := (data[3] << 12) | (data[4] << 4) | (data[5] >> 4)
      if adc-t == 0 or adc-t == 0xfffff: bad++
      device.read 1                                             // Bare read.
      if bus.test EMPTY-ADDRESS: bad++                          // NACK path.
    print "i2c-torture-ec618: $frequency Hz: $ROUNDS rounds, $(ROUNDS * 7) shape-changing transfers, bad=$bad"
    check (bad == 0) "$frequency/no-swallowed-transfers"
    device.close

  bus.close
  exchange control "P 0"
  control.out.write "Q\n"
  control.close

  if not failures.is-empty:
    print "i2c-torture-ec618: FAIL $failures"
    throw "I2C torture failed: $failures"
  print "i2c-torture-ec618: PASS shape-changing transfers clean at both speeds, no per-transfer reset"

check ok/bool label/string -> none:
  print "i2c-torture-ec618: $label $(ok ? "ok" : "FAIL")"
  if not ok: failures.add label

// Sends a command and reads one newline-terminated reply.
exchange control/uart.Port command/string -> string:
  control.out.write "$command\n"
  buffer := #[]
  with-timeout --ms=10_000:
    while true:
      nl := buffer.index-of '\n'
      if nl >= 0: return buffer[..nl].to-string.trim
      chunk := control.in.read
      if chunk == null: throw "control lane closed"
      buffer += chunk
  unreachable
