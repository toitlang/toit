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

DEFAULT-FREQUENCY ::= 400_000

/**
Bus for communicating using I2C.

The communication is synchronous.
*/
class Bus:
  i2c_ := ?
  devices_ := {:}

  /**
  Constructs an I2C bus on the $sda (data) and the $scl (clock) pins using
    the given $frequency.

  Uses $DEFAULT-FREQUENCY by default.

  If the $sda-pullup is true, the SDA pin is pulled up.
  If the $scl-pullup is true, the SCL pin is pulled up.
  Many i2c modules have built-in pull-up resistors, so this is typically not necessary.
  */
  constructor
      --sda/gpio.Pin
      --scl/gpio.Pin
      --frequency=DEFAULT-FREQUENCY
      --sda-pullup/bool=false
      --scl-pullup/bool=false:
    i2c_ = i2c-init_ frequency sda.num scl.num sda-pullup scl-pullup

  /**
  Scans all valid addresses.

  Returns the set of addresses that responded.

  Some addresses are reserved and are not scanned. See
    https://www.i2c-bus.org/addressing/.

  This process can be very slow if the bus is not behaving correctly. If a
    call to this method takes more than a few milliseconds, check your hardware.
    Make sure that you use the correct SDA/SCL pins, that the bus is pulled up,
    and that nothing is pulling the bus down. Pull-up resistors are typically
    included in I2C modules, but you may need to add them (either using the
    constructor's `--sda-pullup`/`--scl-pullup` or external resistors) if you
    are using separate components.
  */
  scan -> Set:
    result := {}
    for i := 0x08; i < 0x78; i++:
      if test i: result.add i
    return result

  /** Tests if the $address responds. */
  test address -> bool:
    write_ address #[]: return false
    return true

  /**
  Closes this I2C bus.

  Releases the resources associated with this bus.
  */
  close -> none:
    devices_.values.do: it.close
    i2c-close_ i2c_

  /**
  Gets the device connected on the $i2c-address.

  It is an error to connect a device on an address already in use.
    The device can be released with $Device.close.
  */
  device i2c-address/int -> Device:
    if devices_.contains i2c-address: throw "Device already connected"
    device := Device.init_ this i2c-address
    devices_[i2c-address] = device
    return device

  /** See $(Device.write bytes). */
  write_ i2c-address/int bytes/ByteArray [failure]:
    r := i2c-write_ i2c_ i2c-address bytes
    if r: return failure.call "I2C_WRITE_FAILED"
    return r

  /** See $(Device.write-reg register bytes). */
  write-reg_ i2c-address/int register/int bytes/ByteArray [failure]:
    r := i2c-write-reg_ i2c_ i2c-address register bytes
    if r: return failure.call "I2C_WRITE_FAILED"
    return r

  /** See $(Device.write-address address bytes). */
  write-address_ i2c-address/int address/ByteArray bytes/ByteArray [failure]:
    r := i2c-write-address_ i2c_ i2c-address address bytes
    if r: return failure.call "I2C_WRITE_FAILED"
    return r

  /** See $(Device.read size). */
  read_ i2c-address/int size/int [failure] -> ByteArray:
    b := i2c-read_ i2c_ i2c-address size
    if not b: return failure.call "I2C_READ_FAILED"
    return b

  /** See $(Device.read-reg register size). */
  read-reg_ i2c-address/int reg/int size/int [failure] -> ByteArray:
    b := i2c-read-reg_ i2c_ i2c-address reg size
    if not b: return failure.call "I2C_READ_FAILED"
    return b

  /** See $(Device.read-address address size). */
  read-address_ i2c-address/int address/ByteArray size/int [failure] -> ByteArray:
    b := i2c-read-address_ i2c_ i2c-address address size
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
  Writes the $bytes to the device.

  # Advanced
  The write operation is executed by sending:
  - a 'start',
  - the device's I2C address with the READ/WRITE bit set to WRITE. This is accomplished by
    shifting the I2C address by one and clearing the least-significant bit. The device must ack
  - each byte.
  */
  write bytes/ByteArray:
    write bytes: throw it

  /**
  Variant of $(write bytes).
  Calls the $failure block if the write fails.
  */
  write bytes/ByteArray [failure]:
    i2c_.write_ address bytes failure

  /**
  Writes the $bytes to the device at the given $register.

  The $register value must satisfy 0 <= $register < 256.
  This is a convenience method and equivalent to prepending the $register byte to $bytes
    and then calling $(write bytes).
  */
  write-reg register/int bytes/ByteArray:
    write-reg register bytes: throw it

  /**
  Variant of $(write-reg register bytes).
  Calls the $failure block if the write fails.
  */
  write-reg register/int bytes/ByteArray [failure]:
    i2c_.write-reg_ address register bytes failure

  /**
  Writes the $bytes to the device at the given $address.

  This is a convenience method and equivalent to prepending the $address bytes to $bytes
    and then calling $(write bytes).
  */
  write-address address/ByteArray bytes/ByteArray:
    write-address address bytes: throw it

  /**
  Variant of $(write-address address bytes).
  Calls the $failure block if the write fails.
  */
  write-address address/ByteArray bytes/ByteArray [failure]:
    i2c_.write-address_ this.address address bytes failure

  /**
  Reads $size bytes from the device.

  # Advanced
  The read operation is executed by sending:
  - a 'start',
  - the device's I2C address with the READ/WRITE bit set to READ. This is accomplished by
    shifting the I2C address by one and setting the least-significant bit. The device must ack.
  Then it reads $size bytes, sending an 'ack' for each byte except for the last, where
    receipt is confirmed with a 'nack'.
  Finally it sends a 'stop'.
  */
  read size/int -> ByteArray:
    return read size: throw it

  /**
  Variant of $(read size).
  Calls the $failure block if the read fails.
  */
  read size/int [failure] -> ByteArray:
    return i2c_.read_ address size failure

  /**
  Reads $size bytes from the given $register.

  The $register value must satisfy 0 <= $register < 256.
  Equivalent to calling $read-address with a byte array containing
    the register value.
  */
  read-reg register/int size/int -> ByteArray:
    return read-reg register size: throw it

  /**
  Variant of $(read-reg register size).
  Calls the $failure block if the read fails.
  */
  read-reg register/int size/int [failure] -> ByteArray:
    return i2c_.read-reg_ address register size failure

  /**
  Reads $size bytes from the given $address.

  # Advanced
  This operation is executed by sending:
  - a 'start',
  - the device's I2C address with the READ/WRITE bit set to WRITE. This is accomplished by
    shifting the I2C address by one and clearing the least-significant bit. The device must ack.
  - the $address bytes, each needing an 'ack'.
  - another 'start'
  - the device's I2C address with the READ/WRITE bit set to READ. This is accomplished by
    shifting the I2C address by one and setting the least-significant bit. The device must ack.
  Then it reads $size bytes, sending an 'ack' for each byte except for the last, where
    receipt is confirmed with a 'nack'.
  Finally it sends a 'stop'.
  */
  read-address address/ByteArray size/int -> ByteArray:
    return read-address address size: throw it

  /**
  Variant of $(read-address address size).
  Calls the $failure block if the operation fails.
  */
  read-address address/ByteArray size/int [failure] -> ByteArray:
    return i2c_.read-address_ this.address address size failure

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
  read-bytes reg count:
    return device_.read-reg reg count

  /** See $super. */
  read-bytes reg count [failure]:
    return device_.read-reg reg count failure

  /** See $super. */
  write-bytes reg bytes:
    data := ByteArray bytes.size + 1
    data[0] = reg
    data.replace 1 bytes
    device_.write data

i2c-init_ frequency sda scl sda-pullup scl-pullup:
  #primitive.i2c.init

i2c-close_ i2c:
  #primitive.i2c.close

i2c-read_ i2c address size:
  #primitive.i2c.read

i2c-read-reg_ i2c address reg size:
  #primitive.i2c.read-reg

i2c-read-address_ i2c i2c-address reg-address size:
  #primitive.i2c.read-address

i2c-write_ i2c address bytes:
  #primitive.i2c.write

i2c-write-reg_ i2c address reg bytes:
  #primitive.i2c.write-reg

i2c-write-address_ i2c i2c-address reg-address bytes:
  #primitive.i2c.write-address
