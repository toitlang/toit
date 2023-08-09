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
  static I2C-ADDRESS       ::= 0x10
  static I2C-ADDRESS-ALT-1 ::= 0x11
  static I2C-ADDRESS-ALT-2 ::= 0x12
  static I2C-ADDRESS-ALT-3 ::= 0x13

  // Registers for communicating with the magnetometer.
  static REG-CHIP-ID    ::= 0x40
  static REG-XOUT-LSB   ::= 0x42
  static REG-XOUT-MSB   ::= 0x43
  static REG-YOUT-LSB   ::= 0x44
  static REG-YOUT-MSB   ::= 0x45
  static REG-ZOUT-LSB   ::= 0x46
  static REG-ZOUT-MSB   ::= 0x47
  static REG-ROUT-LSB   ::= 0x48
  static REG-ROUT-MSB   ::= 0x49
  static REG-INT-STATUS ::= 0x4A
  static REG-PWR-CNTL1  ::= 0x4B
  static REG-PWR-CNTL2  ::= 0x4C
  static REG-INT-EN-1   ::= 0x4D
  static REG-INT-EN-2   ::= 0x4E
  static REG-LOW-THS    ::= 0x4F
  static REG-HIGH-THS   ::= 0x50
  static REG-REP-XY     ::= 0x51
  static REG-REP-Z      ::= 0x52

  // Expected result of reading REG_CHIP_ID.
  static CHIP-ID        ::= 0x32

  registers_/serial.Registers ::= ?

  constructor device/serial.Device:
    registers_ = device.registers

  on -> none:
    // Soft reset result in suspend mode.
    registers_.write-u8 REG-PWR-CNTL1 0x82
    pause_
    // Setting bit 0 to “1” brings the device up from suspend mode to sleep mode.
    registers_.write-u8 REG-PWR-CNTL1 0x01
    pause_
    validate-chip-id
    // Configure the sensor.
    registers_.write-u8 REG-PWR-CNTL2 0x00 // Normal Mode, ODR = 10 Hz
    registers_.write-u8 REG-INT-EN-2  0x84 // X, Y, Z-Axis enabled
    registers_.write-u8 REG-REP-XY    0x04 // No. of Repetitions for X-Y Axis = 9
    registers_.write-u8 REG-REP-Z     0x0F // No. of Repetitions for Z-Axis = 15
    pause_

  off -> none:
    // Setting bit 0 to “0” results in suspend mode.
    registers_.write-u8 REG-PWR-CNTL1 0x00

  // Disable puts the magnetometer in a idle mode, while configuring the
  // interrupt to be push/pull and active high.
  disable -> none:
    registers_.write-u8 REG-INT-EN-2 0b01000001
    pause_
    registers_.write-u8 REG-PWR-CNTL2 0b00000110 // Sleep mode.

  read -> Point3f:
    return Point3f
      read-value-13_ REG-XOUT-LSB REG-XOUT-MSB
      read-value-13_ REG-YOUT-LSB REG-YOUT-MSB
      read-value-15_ REG-ZOUT-LSB REG-ZOUT-MSB

  validate-chip-id -> none:
    // Validate the chip ID
    id ::= registers_.read-u8 REG-CHIP-ID
    if id != CHIP-ID: throw "Unknown Magnetometer chip id $id"

  read-value-13_ reg-lsb reg-msb -> float:
    // 5-bit LSB part [4:0] of the 13 bit output data of the X or Y-channel.
    // 8-bit MSB part [12:5] of the 13 bit output data of the X or Y-channel.
    lsb ::= registers_.read-u8 reg-lsb
    msb ::= registers_.read-u8 reg-msb
    value := ((msb * 256) + (lsb & 0xF8)) / 8
    value = value <= 4095 ? value : value - 8192
    return value / 16.0

  read-value-15_ reg-lsb reg-msb -> float:
    // 7-bit LSB part [6:0] of the 15 bit output data of the Z-channel.
    // 8-bit MSB part [14:7] of the 15 bit output data of the Z-channel.
    lsb ::= registers_.read-u8 reg-lsb
    msb ::= registers_.read-u8 reg-msb
    value := ((msb * 256) + (lsb & 0xFE)) / 2
    value = value <= 16383 ? value : value - 32768
    return value / 16.0

  pause_ -> none:
    // Take a break to make sure the sensor is ready after reconfiguration.
    sleep --ms=100
