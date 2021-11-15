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
  static I2C_ADDRESS     ::= 0x68
  static I2C_ADDRESS_ALT ::= 0x69

  //  Decimal value Angular rate (in 2000°/s range mode)
  //     +32767     + 2000°/s
  //          …          …
  //          0          0°/s
  //          …          …
  //     -32767     - 2000°/s
  // And finally convert to radians.
  static SCALE_FACTOR_ ::= 2000.0 / 32767.0 * math.PI / 180.0

  // Power modes.
  static PM_NORMAL_MODE ::= 0b0000_0000
  static PM_DEEP_SUSPEND ::= 0b0010_0000
  static PM_SUSPEND ::= 0b1000_0000

  static PM_FAST_POWER_UP ::= 0b1000_0000

  // Registers for communicating with the gyroscope.
  static REG_CHIP_ID    ::= 0x00
  static REG_RATE_X_LSB ::= 0x02
  static REG_RATE_X_MSB ::= 0x03
  static REG_RATE_Y_LSB ::= 0x04
  static REG_RATE_Y_MSB ::= 0x05
  static REG_RATE_Z_LSB ::= 0x06
  static REG_RATE_Z_MSB ::= 0x07

  // Expected result of reading REG_CHIP_ID.
  static CHIP_ID        ::= 0x0F

  static REG_LPM1          ::= 0x11
  static REG_LPM2          ::= 0x12
  static REG_BGW_SOFTRESET ::= 0x14
  static REG_INT_EN_1      ::= 0x16
  static REG_INT_RST_LATCH ::= 0x21

  registers_/serial.Registers ::= ?

  constructor device/serial.Device:
    registers_ = device.registers

  on -> none:
    soft_reset
    validate_chip_id
    // Wait for initial reading to be available.
    sleep --ms=20

  off -> none:
    // Enter deep sleep.
    deep_suspend_mode

  /**
  Enter deep suspend mode.

  Deep suspend can be left with $normal_mode or $soft_reset.
  */
  deep_suspend_mode -> none:
    registers_.write_u8 REG_LPM1 PM_DEEP_SUSPEND

  power_up_fast_mode -> none:
    registers_.write_u8 REG_LPM2 PM_FAST_POWER_UP
    registers_.write_u8 REG_LPM1 PM_SUSPEND

  suspend_mode -> none:
    registers_.write_u8 REG_LPM1 PM_SUSPEND

  normal_mode -> none:
    registers_.write_u8 REG_LPM1 PM_NORMAL_MODE

  soft_reset -> none:
    registers_.write_u8 REG_BGW_SOFTRESET 0xB6
    sleep --ms=2

  read -> math.Point3f:
    bytes := registers_.read_bytes REG_RATE_X_LSB 6
    return math.Point3f
      (binary.LITTLE_ENDIAN.int16 bytes 0) * SCALE_FACTOR_
      (binary.LITTLE_ENDIAN.int16 bytes 2) * SCALE_FACTOR_
      (binary.LITTLE_ENDIAN.int16 bytes 4) * SCALE_FACTOR_

  validate_chip_id -> none:
    // Validate the chip ID
    id ::= registers_.read_u8 REG_CHIP_ID
    if id != CHIP_ID: throw "Unknown Gyroscope chip id $id"
