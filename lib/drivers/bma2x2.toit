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
  static I2C_ADDRESS     ::= 0x18
  static I2C_ADDRESS_ALT ::= 0x19

  // Configuration values.
  static RANGE_2G ::= 0b0011
  static RANGE_4G ::= 0b0101
  static RANGE_8G ::= 0b1000
  static RANGE_16G ::= 0b1100

  static BANDWIDTH_8Hz ::= 0x08
  static BANDWIDTH_16Hz ::= 0x09
  static BANDWIDTH_1kHz ::= 0x0F

  // Interrupts
  static MASK_ANY_MOTION ::= 0b0000_0100

  static MASK_ANY_MOTION_ALL_AXES ::= 0b0000_0111

  static SLOPE_DURATION_1 ::= 0b0000_0000
  static SLOPE_DURATION_2 ::= 0b0000_0001
  static SLOPE_DURATION_3 ::= 0b0000_0010
  static SLOPE_DURATION_4 ::= 0b0000_0011

  static RESET_LATCH ::= 0b1000_0000

  static NON_LATCHED ::=       0b0000_0000
  static TEMPORARY_250_MS ::=  0b0000_0001
  static TEMPORARY_500_MS ::=  0b0000_0010
  static TEMPORARY_1_S ::=     0b0000_0011
  static TEMPORARY_2_S ::=     0b0000_0100
  static TEMPORARY_4_S ::=     0b0000_0101
  static TEMPORARY_8_S ::=     0b0000_0110
  // static LATCHED ::=        0b0000_0111
  // static NON_LATCHED ::=    0b0000_1000
  static TEMPORARY_250_MUS ::= 0b0000_1001
  static TEMPORARY_500_MUS ::= 0b0000_1010
  static TEMPORARY_1_MS ::=    0b0000_1011
  static TEMPORARY_12_5_MS ::= 0b0000_1100
  static TEMPORARY_25_MS ::=   0b0000_1101
  static TEMPORARY_50_MS ::=   0b0000_1110
  static LATCHED ::=           0b0000_1111

  // Power modes
  static PM_NORMAL       ::= 0b0000_0000
  static PM_DEEP_SUSPEND ::= 0b0010_0000
  static PM_LOW_POWER    ::= 0b0100_0000
  static PM_SUSPEND      ::= 0b1000_0000

  static LOWPOWER_MODE_2 ::= 0b0100_0000

  // Calibration
  static MASK_CALIBRATION_READY ::= 0b0001_0000

  static RESET_OFFSET ::= 0b1000_0000

  // Registers for communicating with the accelerometer.
  static REG_CHIP_ID       ::= 0x00
  static REG_D_X_LSB       ::= 0x02
  static REG_D_X_MSB       ::= 0x03
  static REG_D_Y_LSB       ::= 0x04
  static REG_D_Y_MSB       ::= 0x05
  static REG_D_Z_LSB       ::= 0x06
  static REG_D_Z_MSB       ::= 0x07
  static REG_PMU_RANGE     ::= 0x0F
  static REG_PMU_BW        ::= 0x10
  static REG_D_HBW         ::= 0x13
  static REG_INT_EN_0      ::= 0x16
  static REG_INT_EN_1      ::= 0x17
  static REG_INT_EN_2      ::= 0x18
  static REG_INT_OUT_CTRL  ::= 0x20
  static REG_INT_MAP_0     ::= 0x19
  static REG_BGW_SPI3_WDT  ::= 0x34
  static REG_PMU_LPW       ::= 0x11
  static REG_PMU_LOW_POWER ::= 0x12
  static REG_INT_0         ::= 0x22
  static REG_INT_1         ::= 0x23
  static REG_INT_2         ::= 0x24
  static REG_INT_3         ::= 0x25
  static REG_INT_4         ::= 0x26
  static REG_INT_5         ::= 0x27
  static REG_INT_6         ::= 0x28
  static REG_INT_7         ::= 0x29
  static REG_INT_8         ::= 0x2A
  static REG_INT_9         ::= 0x2B
  static REG_INT_A         ::= 0x2C
  static REG_INT_B         ::= 0x2D
  static REG_INT_C         ::= 0x2E
  static REG_INT_D         ::= 0x2F
  static REG_BGW_SOFTRESET ::= 0x14
  static REG_INT_STATUS_0  ::= 0X09
  static REG_INT_STATUS_1  ::= 0X0A
  static REG_INT_STATUS_3  ::= 0x0C
  static REG_INT_RST_LATCH ::= 0x21
  static REG_OFC_CTRL      ::= 0x36
  static REG_OFC_SETTING   ::= 0x37

  // Expected result of reading REG_CHIP_ID.
  static CHIP_ID           ::= 0xFA

  // Measured in g/LSB.
  static RESOLUTION_2G  ::= 0.98 / 1000.0
  static RESOLUTION_4G  ::= 1.95 / 1000.0
  static RESOLUTION_8G  ::= 3.91 / 1000.0
  static RESOLUTION_16G ::= 7.81 / 1000.0

  // Measured in g/LSB.
  static THRESHOLD_RESOLUTION_2G  ::= 3.91 / 1000.0
  static THRESHOLD_RESOLUTION_4G  ::= 7.81 / 1000.0
  static THRESHOLD_RESOLUTION_8G  ::= 15.63 / 1000.0
  static THRESHOLD_RESOLUTION_16G ::= 31.25 / 1000.0

  static SLEEP_DURATION_40HZ ::= 0b10110
  static SLEEP_DURATION_10HZ ::= 0b11010
  static SLEEP_DURATION_2HZ  ::= 0b11100
  static SLEEP_DURATION_1HZ  ::= 0b11110

  registers_/serial.Registers ::= ?

  resolution_/float := RESOLUTION_2G
  threshold_resolution_/float := THRESHOLD_RESOLUTION_2G

  constructor device/serial.Device:
    registers_ = device.registers

  on -> none:
    soft_reset
    validate_chip_id
    configure

  off -> none:
    deep_suspend_mode

  configure --range=RANGE_2G --bandwidth=BANDWIDTH_1kHz -> none:
    registers_.write_u8 REG_PMU_RANGE range
    registers_.write_u8 REG_PMU_BW bandwidth
    registers_.write_u8 REG_INT_RST_LATCH (TEMPORARY_250_MS | RESET_LATCH)
    if range == RANGE_2G:
      resolution_ = RESOLUTION_2G
      threshold_resolution_ = THRESHOLD_RESOLUTION_2G
    else if range == RANGE_4G:
      resolution_ = RESOLUTION_4G
      threshold_resolution_ = THRESHOLD_RESOLUTION_4G
    else if range == RANGE_8G:
      resolution_ = RESOLUTION_8G
      threshold_resolution_ = THRESHOLD_RESOLUTION_8G
    else if range == RANGE_16G:
      resolution_ = RESOLUTION_16G
      threshold_resolution_ = THRESHOLD_RESOLUTION_16G
    sleep --ms=10

  /**
  Enter deep suspend mode.

  Call $normal_mode or $soft_reset to enter normal mode.
  */
  deep_suspend_mode:
    registers_.write_u8 REG_PMU_LPW PM_DEEP_SUSPEND

  /**
  Enter suspend mode.

  Can transition to deep suspend, normal or low power mode 1.
  */
  suspend_mode:
    registers_.write_u8 REG_PMU_LPW PM_SUSPEND

  /**
  Enter standby mode.

  Can transition to deep suspend, normal or low power mode 2.
  */
  standby_mode:
    registers_.write_u8 REG_PMU_LOW_POWER LOWPOWER_MODE_2
    registers_.write_u8 REG_PMU_LPW PM_SUSPEND

  /**
  Enter low power mode 1.

  Can transition to deep suspend, suspend, or normal mode.
  */
  low_power_mode_1 sleep_duration/int:
    registers_.write_u8 REG_PMU_LOW_POWER 0b0000_0000  // Event-driven time-based (EDT) sampling mode.
    value := PM_LOW_POWER | sleep_duration
    registers_.write_u8 REG_PMU_LPW value

  /**
  Enter low power mode 2.

  Can transition to deep suspend, standby, or normal mode.
  */
  low_power_mode_2:
    registers_.write_u8 REG_PMU_LOW_POWER PM_LOW_POWER
    registers_.write_u8 REG_PMU_LPW PM_SUSPEND

  /**
  Configure wakeup by any motion, sustained above $threshold g.
  */
  wakeup_any_motion threshold/float?:
    if not threshold:
      registers_.write_u8 REG_INT_EN_0 0b0000_0000
      return

    // Set the number of samples.
    // TODO(anders): We should consider somehow working this into low-power sampling rate
    // and expose a duration.
    registers_.write_u8 REG_INT_5 0b000000_11  // Use 4 samples.

    // Set the threshold.
    lsb := threshold / threshold_resolution_
    registers_.write_u8 REG_INT_6 lsb.to_int

    // Map interrupts to the INT1 pin.
    registers_.write_u8 REG_INT_MAP_0 0b0000_0100

    // Finally enable the interrupt.
    // TODO(anders): Preserve the upper 5 bits.
    registers_.write_u8 REG_INT_EN_0 0b0000_0111

  /**
  Enter normal mode.

  Can transition to all other power modes.
  */
  normal_mode:
    registers_.write_u8 REG_PMU_LPW PM_NORMAL

  get_d_value_ reg_lsb/int reg_msb/int -> float:
    lsb  ::= registers_.read_u8 reg_lsb
    msb ::= registers_.read_u8 reg_msb
    if not lsb & 0x1: return float.NAN  // Bail out if there is no new data.
    value := ((msb << 8) | lsb) >> 4
    value = value <= 2047 ? value : value - 4096
    return value * resolution_

  read -> Point3f:
    return Point3f
      get_d_value_ REG_D_X_LSB REG_D_X_MSB
      get_d_value_ REG_D_Y_LSB REG_D_Y_MSB
      get_d_value_ REG_D_Z_LSB REG_D_Z_MSB

  validate_chip_id -> none:
    // Validate the chip ID
    id ::= registers_.read_u8 REG_CHIP_ID
    if id != CHIP_ID: throw "Unknown Accelerometer chip id $id"

  soft_reset -> none:
    registers_.write_u8 REG_BGW_SOFTRESET 0xB6 // reset accelerometer
    sleep --ms=2

  // Precondition: the range should be 2g (see $configure).
  fast_compensation -> none:
    // TODO(Lau): should we set the range or perhaps check that it is as expected?
    registers_.write_u8 REG_OFC_CTRL RESET_OFFSET // Reset offset registers
    // Set target values:
    // x=0g, y=0g, z=0
    registers_.write_u8 REG_OFC_SETTING 0b0000_0000
    3.repeat:
      calibration_trigger := (it + 1) << 5
      registers_.write_u8 REG_OFC_CTRL calibration_trigger
      while 0 == ((registers_.read_u8 REG_OFC_CTRL) & MASK_CALIBRATION_READY): sleep --ms=10
