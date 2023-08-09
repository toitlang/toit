// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import serial
import math show Point3f

/**
Driver for Bosch accelerometers.

This driver supports the following devices:
* BMA280
* BMA255
* BMA253
* BMA250E
* BMA22E
* BMA220
* BMI055 - Combination of bma2x2 + bmg160 APIs
* BMX055 - Combination of bma2x2 + bmg160 + bmm050 APIs
* BMC150 - Combination of bma2x2 + bmm050 APIs
* BMC056 - Combination of bma2x2 + bmm050 APIs

(Datasheet: https://www.bosch-sensortec.com/media/boschsensortec/downloads/motion_sensors_2/absolute_orientation_sensors/bmx055/bst-bmx055-ds000.pdf)
*/
class Bma2x2:
  static I2C-ADDRESS     ::= 0x18
  static I2C-ADDRESS-ALT ::= 0x19

  // Configuration values.
  static RANGE-2G ::= 0b0011
  static RANGE-4G ::= 0b0101
  static RANGE-8G ::= 0b1000
  static RANGE-16G ::= 0b1100

  static BANDWIDTH-8Hz ::= 0x08
  static BANDWIDTH-16Hz ::= 0x09
  static BANDWIDTH-1kHz ::= 0x0F

  // Interrupts
  static MASK-ANY-MOTION ::= 0b0000_0100

  static MASK-ANY-MOTION-ALL-AXES ::= 0b0000_0111

  static SLOPE-DURATION-1 ::= 0b0000_0000
  static SLOPE-DURATION-2 ::= 0b0000_0001
  static SLOPE-DURATION-3 ::= 0b0000_0010
  static SLOPE-DURATION-4 ::= 0b0000_0011

  static RESET-LATCH ::= 0b1000_0000

  static NON-LATCHED ::=       0b0000_0000
  static TEMPORARY-250-MS ::=  0b0000_0001
  static TEMPORARY-500-MS ::=  0b0000_0010
  static TEMPORARY-1-S ::=     0b0000_0011
  static TEMPORARY-2-S ::=     0b0000_0100
  static TEMPORARY-4-S ::=     0b0000_0101
  static TEMPORARY-8-S ::=     0b0000_0110
  // static LATCHED ::=        0b0000_0111
  // static NON_LATCHED ::=    0b0000_1000
  static TEMPORARY-250-MUS ::= 0b0000_1001
  static TEMPORARY-500-MUS ::= 0b0000_1010
  static TEMPORARY-1-MS ::=    0b0000_1011
  static TEMPORARY-12-5-MS ::= 0b0000_1100
  static TEMPORARY-25-MS ::=   0b0000_1101
  static TEMPORARY-50-MS ::=   0b0000_1110
  static LATCHED ::=           0b0000_1111

  // Power modes
  static PM-NORMAL       ::= 0b0000_0000
  static PM-DEEP-SUSPEND ::= 0b0010_0000
  static PM-LOW-POWER    ::= 0b0100_0000
  static PM-SUSPEND      ::= 0b1000_0000

  static LOWPOWER-MODE-2 ::= 0b0100_0000

  // Calibration
  static MASK-CALIBRATION-READY ::= 0b0001_0000

  static RESET-OFFSET ::= 0b1000_0000

  // Registers for communicating with the accelerometer.
  static REG-CHIP-ID       ::= 0x00
  static REG-D-X-LSB       ::= 0x02
  static REG-D-X-MSB       ::= 0x03
  static REG-D-Y-LSB       ::= 0x04
  static REG-D-Y-MSB       ::= 0x05
  static REG-D-Z-LSB       ::= 0x06
  static REG-D-Z-MSB       ::= 0x07
  static REG-PMU-RANGE     ::= 0x0F
  static REG-PMU-BW        ::= 0x10
  static REG-D-HBW         ::= 0x13
  static REG-INT-EN-0      ::= 0x16
  static REG-INT-EN-1      ::= 0x17
  static REG-INT-EN-2      ::= 0x18
  static REG-INT-OUT-CTRL  ::= 0x20
  static REG-INT-MAP-0     ::= 0x19
  static REG-BGW-SPI3-WDT  ::= 0x34
  static REG-PMU-LPW       ::= 0x11
  static REG-PMU-LOW-POWER ::= 0x12
  static REG-INT-0         ::= 0x22
  static REG-INT-1         ::= 0x23
  static REG-INT-2         ::= 0x24
  static REG-INT-3         ::= 0x25
  static REG-INT-4         ::= 0x26
  static REG-INT-5         ::= 0x27
  static REG-INT-6         ::= 0x28
  static REG-INT-7         ::= 0x29
  static REG-INT-8         ::= 0x2A
  static REG-INT-9         ::= 0x2B
  static REG-INT-A         ::= 0x2C
  static REG-INT-B         ::= 0x2D
  static REG-INT-C         ::= 0x2E
  static REG-INT-D         ::= 0x2F
  static REG-BGW-SOFTRESET ::= 0x14
  static REG-INT-STATUS-0  ::= 0X09
  static REG-INT-STATUS-1  ::= 0X0A
  static REG-INT-STATUS-3  ::= 0x0C
  static REG-INT-RST-LATCH ::= 0x21
  static REG-OFC-CTRL      ::= 0x36
  static REG-OFC-SETTING   ::= 0x37

  // Expected result of reading REG_CHIP_ID.
  static CHIP-ID           ::= 0xFA

  // Measured in g/LSB.
  static RESOLUTION-2G  ::= 0.98 / 1000.0
  static RESOLUTION-4G  ::= 1.95 / 1000.0
  static RESOLUTION-8G  ::= 3.91 / 1000.0
  static RESOLUTION-16G ::= 7.81 / 1000.0

  // Measured in g/LSB.
  static THRESHOLD-RESOLUTION-2G  ::= 3.91 / 1000.0
  static THRESHOLD-RESOLUTION-4G  ::= 7.81 / 1000.0
  static THRESHOLD-RESOLUTION-8G  ::= 15.63 / 1000.0
  static THRESHOLD-RESOLUTION-16G ::= 31.25 / 1000.0

  static SLEEP-DURATION-40HZ ::= 0b10110
  static SLEEP-DURATION-10HZ ::= 0b11010
  static SLEEP-DURATION-2HZ  ::= 0b11100
  static SLEEP-DURATION-1HZ  ::= 0b11110

  registers_/serial.Registers ::= ?

  resolution_/float := RESOLUTION-2G
  threshold-resolution_/float := THRESHOLD-RESOLUTION-2G

  constructor device/serial.Device:
    registers_ = device.registers

  on -> none:
    soft-reset
    validate-chip-id
    configure

  off -> none:
    deep-suspend-mode

  configure --range=RANGE-2G --bandwidth=BANDWIDTH-1kHz -> none:
    registers_.write-u8 REG-PMU-RANGE range
    registers_.write-u8 REG-PMU-BW bandwidth
    registers_.write-u8 REG-INT-RST-LATCH (TEMPORARY-250-MS | RESET-LATCH)
    if range == RANGE-2G:
      resolution_ = RESOLUTION-2G
      threshold-resolution_ = THRESHOLD-RESOLUTION-2G
    else if range == RANGE-4G:
      resolution_ = RESOLUTION-4G
      threshold-resolution_ = THRESHOLD-RESOLUTION-4G
    else if range == RANGE-8G:
      resolution_ = RESOLUTION-8G
      threshold-resolution_ = THRESHOLD-RESOLUTION-8G
    else if range == RANGE-16G:
      resolution_ = RESOLUTION-16G
      threshold-resolution_ = THRESHOLD-RESOLUTION-16G
    sleep --ms=10

  /**
  Enter deep suspend mode.

  Call $normal-mode or $soft-reset to enter normal mode.
  */
  deep-suspend-mode:
    registers_.write-u8 REG-PMU-LPW PM-DEEP-SUSPEND

  /**
  Enter suspend mode.

  Can transition to deep suspend, normal or low power mode 1.
  */
  suspend-mode:
    registers_.write-u8 REG-PMU-LPW PM-SUSPEND

  /**
  Enter standby mode.

  Can transition to deep suspend, normal or low power mode 2.
  */
  standby-mode:
    registers_.write-u8 REG-PMU-LOW-POWER LOWPOWER-MODE-2
    registers_.write-u8 REG-PMU-LPW PM-SUSPEND

  /**
  Enter low power mode 1.

  Can transition to deep suspend, suspend, or normal mode.
  */
  low-power-mode-1 sleep-duration/int:
    registers_.write-u8 REG-PMU-LOW-POWER 0b0000_0000  // Event-driven time-based (EDT) sampling mode.
    value := PM-LOW-POWER | sleep-duration
    registers_.write-u8 REG-PMU-LPW value

  /**
  Enter low power mode 2.

  Can transition to deep suspend, standby, or normal mode.
  */
  low-power-mode-2:
    registers_.write-u8 REG-PMU-LOW-POWER PM-LOW-POWER
    registers_.write-u8 REG-PMU-LPW PM-SUSPEND

  /**
  Configure wakeup by any motion, sustained above $threshold g.
  */
  wakeup-any-motion threshold/float?:
    if not threshold:
      registers_.write-u8 REG-INT-EN-0 0b0000_0000
      return

    // Set the number of samples.
    // TODO(anders): We should consider somehow working this into low-power sampling rate
    // and expose a duration.
    registers_.write-u8 REG-INT-5 0b000000_11  // Use 4 samples.

    // Set the threshold.
    lsb := threshold / threshold-resolution_
    registers_.write-u8 REG-INT-6 lsb.to-int

    // Map interrupts to the INT1 pin.
    registers_.write-u8 REG-INT-MAP-0 0b0000_0100

    // Finally enable the interrupt.
    // TODO(anders): Preserve the upper 5 bits.
    registers_.write-u8 REG-INT-EN-0 0b0000_0111

  /**
  Enter normal mode.

  Can transition to all other power modes.
  */
  normal-mode:
    registers_.write-u8 REG-PMU-LPW PM-NORMAL

  get-d-value_ reg-lsb/int reg-msb/int -> float:
    lsb  ::= registers_.read-u8 reg-lsb
    msb ::= registers_.read-u8 reg-msb
    if not lsb & 0x1: return float.NAN  // Bail out if there is no new data.
    value := ((msb << 8) | lsb) >> 4
    value = value <= 2047 ? value : value - 4096
    return value * resolution_

  read -> Point3f:
    return Point3f
      get-d-value_ REG-D-X-LSB REG-D-X-MSB
      get-d-value_ REG-D-Y-LSB REG-D-Y-MSB
      get-d-value_ REG-D-Z-LSB REG-D-Z-MSB

  validate-chip-id -> none:
    // Validate the chip ID
    id ::= registers_.read-u8 REG-CHIP-ID
    if id != CHIP-ID: throw "Unknown Accelerometer chip id $id"

  soft-reset -> none:
    registers_.write-u8 REG-BGW-SOFTRESET 0xB6 // reset accelerometer
    sleep --ms=2

  // Precondition: the range should be 2g (see $configure).
  fast-compensation -> none:
    // TODO(Lau): should we set the range or perhaps check that it is as expected?
    registers_.write-u8 REG-OFC-CTRL RESET-OFFSET // Reset offset registers
    // Set target values:
    // x=0g, y=0g, z=0
    registers_.write-u8 REG-OFC-SETTING 0b0000_0000
    3.repeat:
      calibration-trigger := (it + 1) << 5
      registers_.write-u8 REG-OFC-CTRL calibration-trigger
      while 0 == ((registers_.read-u8 REG-OFC-CTRL) & MASK-CALIBRATION-READY): sleep --ms=10
