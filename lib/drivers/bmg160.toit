// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import serial
import math
import binary

/**
Driver for the gyroscope BMG160.
This sensor is part of the following chips:
* BMX055
*/
class Bmg160:
  static I2C-ADDRESS     ::= 0x68
  static I2C-ADDRESS-ALT ::= 0x69

  //  Decimal value Angular rate (in 2000°/s range mode)
  //     +32767     + 2000°/s
  //          …          …
  //          0          0°/s
  //          …          …
  //     -32767     - 2000°/s
  // And finally convert to radians.
  static SCALE-FACTOR_ ::= 2000.0 / 32767.0 * math.PI / 180.0

  // Power modes.
  static PM-NORMAL-MODE ::= 0b0000_0000
  static PM-DEEP-SUSPEND ::= 0b0010_0000
  static PM-SUSPEND ::= 0b1000_0000

  static PM-FAST-POWER-UP ::= 0b1000_0000

  // Registers for communicating with the gyroscope.
  static REG-CHIP-ID    ::= 0x00
  static REG-RATE-X-LSB ::= 0x02
  static REG-RATE-X-MSB ::= 0x03
  static REG-RATE-Y-LSB ::= 0x04
  static REG-RATE-Y-MSB ::= 0x05
  static REG-RATE-Z-LSB ::= 0x06
  static REG-RATE-Z-MSB ::= 0x07

  // Expected result of reading REG_CHIP_ID.
  static CHIP-ID        ::= 0x0F

  static REG-LPM1          ::= 0x11
  static REG-LPM2          ::= 0x12
  static REG-BGW-SOFTRESET ::= 0x14
  static REG-INT-EN-1      ::= 0x16
  static REG-INT-RST-LATCH ::= 0x21

  registers_/serial.Registers ::= ?

  constructor device/serial.Device:
    registers_ = device.registers

  on -> none:
    soft-reset
    validate-chip-id
    // Wait for initial reading to be available.
    sleep --ms=20

  off -> none:
    // Enter deep sleep.
    deep-suspend-mode

  /**
  Enter deep suspend mode.

  Deep suspend can be left with $normal-mode or $soft-reset.
  */
  deep-suspend-mode -> none:
    registers_.write-u8 REG-LPM1 PM-DEEP-SUSPEND

  power-up-fast-mode -> none:
    registers_.write-u8 REG-LPM2 PM-FAST-POWER-UP
    registers_.write-u8 REG-LPM1 PM-SUSPEND

  suspend-mode -> none:
    registers_.write-u8 REG-LPM1 PM-SUSPEND

  normal-mode -> none:
    registers_.write-u8 REG-LPM1 PM-NORMAL-MODE

  soft-reset -> none:
    registers_.write-u8 REG-BGW-SOFTRESET 0xB6
    sleep --ms=2

  read -> math.Point3f:
    bytes := registers_.read-bytes REG-RATE-X-LSB 6
    return math.Point3f
      (binary.LITTLE-ENDIAN.int16 bytes 0) * SCALE-FACTOR_
      (binary.LITTLE-ENDIAN.int16 bytes 2) * SCALE-FACTOR_
      (binary.LITTLE-ENDIAN.int16 bytes 4) * SCALE-FACTOR_

  validate-chip-id -> none:
    // Validate the chip ID
    id ::= registers_.read-u8 REG-CHIP-ID
    if id != CHIP-ID: throw "Unknown Gyroscope chip id $id"
