// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import serial

/**
I2C is a serial communication bus able to address multiple devices along the same 2-wire bus.

To set up an I2C bus:
```
import gpio
import i2c

main:
  bus := i2c.Bus
    --sda=gpio.Pin 21
    --scl=gpio.Pin 22
```

An I2C bus can be associated with a number of devices. Each device must have a unique I2C address. The address can be found in the datasheet for the selected peripheral - it's a 7-bit integer.

In case of the Bosch [BME280 sensor](https://cdn.sparkfun.com/assets/e/7/3/b/1/BME280_Datasheet.pdf), the address is `0x76`:

```
  device := bus.device 0x76
```
*/

DEFAULT_FREQUENCY ::= 400_000

/**
Bus for communicating using I2C.

The communication is synchronous.
*/
class Bus:
  i2c_ := ?
  devices_ := {:}

  /**
  Constructs an I2C bus on the $sda (data) and the $scl (clock) pins using
    the given $frequency. Uses $DEFAULT_FREQUENCY by default.
  */
  constructor --sda/gpio.Pin --scl/gpio.Pin --frequency=DEFAULT_FREQUENCY:
    i2c_ = i2c_init_ frequency sda.num scl.num

  /**
  Scans all valid addresses.

  Returns the set of addresses that responded.
  */
  scan -> Set:
    result := {}
    for i := 0x08; i < 0x78; i++:
      if test i: result.add i
    return result

  /** Tests if the $address responds. */
  test address -> bool:
    empty := ByteArray 0
    write_ address empty: return false
    return true

  /**
  Closes this I2C bus.

  Releases the resources associated with this bus.
  */
  close -> none:
    devices_.keys.do: it.close
    i2c_close_ i2c_

  /**
  Gets the device connected on the $address.

  It is an error to connect a device on an address already in use.
    The address can be released with $Device.close.
  */
  device address/int -> Device:
    if devices_.contains address: throw "Device already connected"
    device := Device.init_ this address
    devices_[address] = device
    return device

  write_ address/int bytes/ByteArray [failure]:
    r := i2c_write_ i2c_ address bytes
    if r: return failure.call "I2C_WRITE_FAILED"
    return r

  read_ address/int size/int [failure] -> ByteArray:
    b := i2c_read_ i2c_ address size
    if not b: return failure.call "I2C_READ_FAILED"
    return b

  read_reg_ address/int reg/int size/int [failure] -> ByteArray:
    b := i2c_read_reg_ i2c_ address reg size
    if not b: return failure.call "I2C_READ_FAILED"
    return b

/**
Device connected using the I2C bus.

A device is connected on a specific I2C address that can be found in the data
  sheet of the device.
*/
class Device implements serial.Device:
  /** I2C address of the device. */
  address/int ::= ?

  i2c_/Bus? := ?
  registers_/Registers? := null

  /** Deprecated. Use $(Bus.device address).  */
  constructor .i2c_ .address:

  constructor.init_ .i2c_ .address:

  /**
  See $serial.Device.registers.

  Always returns the same object.
  */
  registers -> serial.Registers:
    if not registers_: registers_= Registers.init_ this
    return registers_

  /**
  Variant of $(write bytes [failure]).

  Throws if the write fails.
  */
  write bytes/ByteArray:
    write bytes: throw it

  /**
  Writes the $bytes to the device.

  Calls the $failure block if the write fails.
  */
  write bytes/ByteArray [failure]:
    i2c_.write_ address bytes failure

  /**
  Variant of $(read size [failure]).

  Throws if the read fails.
  */
  read size/int -> ByteArray:
    return read size: throw it

  /**
  Reads $size bytes from the device.

  Calls the $failure block if the read fails.
  */
  read size/int [failure] -> ByteArray:
    return i2c_.read_ address size failure

  /**
  Variant of $(read_reg register size [failure]).

  Throws if the read fails.
  */
  read_reg register/int size/int -> ByteArray:
    return read_reg register size: throw it

  /**
  Reads $size bytes from the $register.

  Calls the $failure block if the read fails.
  */
  read_reg register/int size/int [failure] -> ByteArray:
    return i2c_.read_reg_ address register size failure

  /** Closes this device and releases the I2C address. */
  close -> none:
    if not i2c_: return
    i2c_.devices_.remove address
    i2c_ = null

/**
Registers for an I2C device.
*/
class Registers extends serial.Registers:
  device_/Device ::= ?

  /**
  Deprecated. Use $(Device.registers).
  */
  constructor .device_:

  constructor.init_ .device_:

  /** See $super. */
  read_bytes reg count:
    return device_.read_reg reg count

  /** See $super. */
  read_bytes reg count [failure]:
    return device_.read_reg reg count failure

  /** See $super. */
  write_bytes reg bytes:
    data := ByteArray bytes.size + 1
    data[0] = reg
    data.replace 1 bytes
    device_.write data

i2c_init_ frequency sda scl:
  #primitive.i2c.init

i2c_close_ i2c:
  #primitive.i2c.close

i2c_read_ i2c address size:
  #primitive.i2c.read

i2c_read_reg_ i2c address reg size:
  #primitive.i2c.read_reg

i2c_write_ i2c address bytes:
  #primitive.i2c.write
