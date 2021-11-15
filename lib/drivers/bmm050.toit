// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import serial
import math show Point3f

/**
Driver for the magnetometer BMG160.
This sensor is part of the following chips:
* BMX055
*/
class Bmm050:
  static I2C_ADDRESS       ::= 0x10
  static I2C_ADDRESS_ALT_1 ::= 0x11
  static I2C_ADDRESS_ALT_2 ::= 0x12
  static I2C_ADDRESS_ALT_3 ::= 0x13

  // Registers for communicating with the magnetometer.
  static REG_CHIP_ID    ::= 0x40
  static REG_XOUT_LSB   ::= 0x42
  static REG_XOUT_MSB   ::= 0x43
  static REG_YOUT_LSB   ::= 0x44
  static REG_YOUT_MSB   ::= 0x45
  static REG_ZOUT_LSB   ::= 0x46
  static REG_ZOUT_MSB   ::= 0x47
  static REG_ROUT_LSB   ::= 0x48
  static REG_ROUT_MSB   ::= 0x49
  static REG_INT_STATUS ::= 0x4A
  static REG_PWR_CNTL1  ::= 0x4B
  static REG_PWR_CNTL2  ::= 0x4C
  static REG_INT_EN_1   ::= 0x4D
  static REG_INT_EN_2   ::= 0x4E
  static REG_LOW_THS    ::= 0x4F
  static REG_HIGH_THS   ::= 0x50
  static REG_REP_XY     ::= 0x51
  static REG_REP_Z      ::= 0x52

  // Expected result of reading REG_CHIP_ID.
  static CHIP_ID        ::= 0x32

  registers_/serial.Registers ::= ?

  constructor device/serial.Device:
    registers_ = device.registers

  on -> none:
    // Soft reset result in suspend mode.
    registers_.write_u8 REG_PWR_CNTL1 0x82
    pause_
    // Setting bit 0 to “1” brings the device up from suspend mode to sleep mode.
    registers_.write_u8 REG_PWR_CNTL1 0x01
    pause_
    validate_chip_id
    // Configure the sensor.
    registers_.write_u8 REG_PWR_CNTL2 0x00 // Normal Mode, ODR = 10 Hz
    registers_.write_u8 REG_INT_EN_2  0x84 // X, Y, Z-Axis enabled
    registers_.write_u8 REG_REP_XY    0x04 // No. of Repetitions for X-Y Axis = 9
    registers_.write_u8 REG_REP_Z     0x0F // No. of Repetitions for Z-Axis = 15
    pause_

  off -> none:
    // Setting bit 0 to “0” results in suspend mode.
    registers_.write_u8 REG_PWR_CNTL1 0x00

  // Disable puts the magnetometer in a idle mode, while configuring the
  // interrupt to be push/pull and active high.
  disable -> none:
    registers_.write_u8 REG_INT_EN_2 0b01000001
    pause_
    registers_.write_u8 REG_PWR_CNTL2 0b00000110 // Sleep mode.

  read -> Point3f:
    return Point3f
      read_value_13_ REG_XOUT_LSB REG_XOUT_MSB
      read_value_13_ REG_YOUT_LSB REG_YOUT_MSB
      read_value_15_ REG_ZOUT_LSB REG_ZOUT_MSB

  validate_chip_id -> none:
    // Validate the chip ID
    id ::= registers_.read_u8 REG_CHIP_ID
    if id != CHIP_ID: throw "Unknown Magnetometer chip id $id"

  read_value_13_ reg_lsb reg_msb -> float:
    // 5-bit LSB part [4:0] of the 13 bit output data of the X or Y-channel.
    // 8-bit MSB part [12:5] of the 13 bit output data of the X or Y-channel.
    lsb ::= registers_.read_u8 reg_lsb
    msb ::= registers_.read_u8 reg_msb
    value := ((msb * 256) + (lsb & 0xF8)) / 8
    value = value <= 4095 ? value : value - 8192
    return value / 16.0

  read_value_15_ reg_lsb reg_msb -> float:
    // 7-bit LSB part [6:0] of the 15 bit output data of the Z-channel.
    // 8-bit MSB part [14:7] of the 15 bit output data of the Z-channel.
    lsb ::= registers_.read_u8 reg_lsb
    msb ::= registers_.read_u8 reg_msb
    value := ((msb * 256) + (lsb & 0xFE)) / 2
    value = value <= 16383 ? value : value - 32768
    return value / 16.0

  pause_ -> none:
    // Take a break to make sure the sensor is ready after reconfiguration.
    sleep --ms=100
