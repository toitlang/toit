// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import serial

/**
SPI is a serial communication bus able to address multiple devices along a main 3-wire bus with an additional 1 wire per device.

To set up a SPI BUS:
```
import gpio
import serial.protocols.spi as spi

main:
  bus := spi.Bus
    --miso=gpio.Pin 12
    --mosi=gpio.Pin 13
    --clock=gpio.Pin 14
```

When communicating with a device, a unique chip-select (`cs`) Pin is used to signal when the chip in question is addressed. In addition, it's important to not select a device frequency that exceeds the capabilities of the device. The maximum frequency can be found in the datasheet for the selected peripheral.

In case of the Bosch [BME280 sensor](https://cdn.sparkfun.com/assets/e/7/3/b/1/BME280_Datasheet.pdf), the maximum frequency is 10MHz:

```
  device := bus.device
    --cs=gpio.Pin 15
    --frequency=10_000_000
```
*/

/**
Bus for communicating using SPI.

An SPI bus is constructed with 3 main wires for data transmission and a clock.
Each device on the bus is enabled with its own chip-select pin. See $Bus.device.
*/
class Bus:
  spi_ := ?

  /**
  Constructs a new SPI bus using the given $mosi, $miso, and $clock pins.
  */
  constructor --mosi/gpio.Pin?=null --miso/gpio.Pin?=null --clock/gpio.Pin:
    spi_ = spi_init_
      mosi ? mosi.num : -1
      miso ? miso.num : -1
      clock.num

  /** Closes this SPI bus and frees the associated resources. */
  close:
    spi_close_ spi_

  /**
  Configures a device on this SPI bus.

  The device's clock speed is configured to the given $frequency.

  An optional $cs (chip select) and $dc (data/command) pin can be assigned
    for this device. If no $cs pin is provided, then the chip must be enabled
    in software (or hardware, tied to ground, if it's the only chip on the bus).

  The SPI $mode can further be configured in the range [0..3], defaulting
    to 0.

  Some SPI devices have an explicit command and/or address section that can be configured
    using $command_bits and $address_bits.

  # Parameters
  The $mode parameter configures the clock polarity and phase (CPOL and CPHA) for this bus.
  The possible configurations are:
  - 0 (0b00): CPOL=0, CPHA=0
  - 1 (0b01): CPOL=0, CPHA=1
  - 2 (0b10): CPOL=1, CPHA=0
  - 3 (0b11): CPOL=1, CPHA=1
  */
  device
      --cs/gpio.Pin?=null
      --dc/gpio.Pin?=null
      --frequency/int
      --mode/int=0
      --command_bits/int=0
      --address_bits/int=0
      -> Device:
    if mode < 0 or mode > 3: throw "Argument Error"
    cs_num := -1
    if cs: cs_num = cs.num
    dc_num := -1
    if dc:
      dc_num = dc.num
      dc.config --output

    d := spi_device_ spi_ cs_num dc_num command_bits address_bits frequency mode
    return Device_.init_ this d

/**
A device connected with SPI.
*/
interface Device extends serial.Device:
  /** See $serial.Device.registers. */
  registers -> Registers

  /**
  Transfers the given $data to the device.

  If $read is true, then the transfer is full-duplex, and the read data
    replaces the contents of $data.
  If the device has a dc (data/command) pin, then that pin is set to the
    value of $dc.
  If a commands and/or address sections was defined, use $command and
    $address to set the values.
  */
  transfer
      data/ByteArray
      --from/int=0
      --to/int=data.size
      --read/bool=false
      --dc/int=0
      --command/int=0
      --address/int=0

  /** Closes this SPI device and releases resources associated with it. */
  close

/** Device connected to an SPI bus. */
class Device_ implements Device:
  spi_/Bus := ?
  device_ := ?

  registers_/Registers? := null

  /** Deprecated. Use $Bus.device. */
  constructor .spi_ .device_:

  constructor.init_ .spi_ .device_:

  /**
  See $Device.registers.

  Always returns the same object.
  */
  registers -> Registers:
    if not registers_: registers_= Registers.init_ this
    return registers_

  /** See $serial.Device.read. */
  read size/int -> ByteArray:
    bytes := ByteArray size
    transfer bytes --read=true
    return bytes

  /** See $serial.Device.write. */
  write bytes/ByteArray:
    transfer bytes

  /** See $Device.close. */
  close:
    if device_:
      spi_device_close_ spi_.spi_ device_
      device_ = null

  /** See $Device.transfer. */
  transfer
      data/ByteArray
      --from/int=0
      --to/int=data.size
      --read/bool=false
      --dc/int=0
      --command/int=0
      --address/int=0:
    return spi_transfer_ device_ data command address from to read dc

/** Register description of a device connected to an SPI bus. */
class Registers extends serial.Registers:
  device_/Device

  msb_write_ := false

  /** Deprecated. Use $Device.registers. */
  constructor .device_:

  constructor.init_ .device_:

  /**
  Sets the writing mode.

  If set to true, then emits a high most-significant bit (msb) for writes, and
    a low most-significant bit for reads. Generally, this modifies the register
    value that is sent as first byte on the bus.
  If set to false, then it does the opposite: writes emit a low msb, and
    reads start with a high msb.

  The default is false.
  */
  set_msb_write value/bool:
    msb_write_ = value

  /**
  See $super.

  If `msb_write` is set (see $set_msb_write) modifies the register
    value so it has a low most-significant bit.
  */
  read_bytes register/int count/int:
    data := ByteArray 1 + count
    data[0] = mask_reg_ (not msb_write_) register
    transfer_ data --read
    return data.copy 1

  /** See $super. */
  read_bytes register count [failure]:
    // TODO(anders): Can SPI fail?
    return read_bytes register count

  /**
  See $super.

  If `msb_write` is set (see $set_msb_write) modifies the register
    value so it has a high most-significant bit.
  */
  write_bytes reg bytes:
    data := ByteArray 1 + bytes.size
    data[0] = mask_reg_ msb_write_ reg
    data.replace 1 bytes
    transfer_ data

  transfer_ data --read=false:
    device_.transfer data --read=read

  mask_reg_ msb_high reg:
    return (msb_high ? reg | 0x80 : reg & 0x7f).to_int

spi_init_ mosi/int miso/int clock/int:
  #primitive.spi.init

spi_close_ spi:
  #primitive.spi.close

spi_device_ spi cs/int dc/int frequency/int mode/int command_bits/int address_bits/int:
  #primitive.spi.device

spi_device_close_ spi device:
  #primitive.spi.device_close

spi_transfer_ device data/ByteArray command/int address/int from to read/bool dc/int:
  #primitive.spi.transfer
