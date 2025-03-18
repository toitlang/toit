// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import io
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

/** The default frequency for I2C communication. 400kHz. */
DEFAULT-FREQUENCY ::= 400_000

/**
Bus for communicating using I2C.

The communication is synchronous.
*/
class Bus:
  resource_ := ?
  devices_ := {:}
  frequency_/int

  /**
  Deprecated. Use $(constructor --sda --scl --pull-up) instead.

  The $sda-pullup is not fully supported anymore. If either is
    true, then both are pulled up.
  */
  constructor
      --sda/gpio.Pin
      --scl/gpio.Pin
      --frequency/int=DEFAULT_FREQUENCY
      --sda-pullup/bool:
    return Bus --sda=sda --scl=scl --frequency=frequency --pull-up=sda-pullup

  /**
  Deprecated. Use $(constructor --sda --scl --pull-up) instead.

  The $sda-pullup and $scl-pullup flags are not fully supported anymore. If
    either is true, then both are pulled up.
  */
  constructor
      --sda/gpio.Pin
      --scl/gpio.Pin
      --frequency/int=DEFAULT_FREQUENCY
      --sda-pullup/bool=false
      --scl-pullup/bool:
    return Bus --sda=sda --scl=scl --frequency=frequency --pull-up=(sda-pullup or scl-pullup)

  /**
  Constructs an I2C bus on the $sda (data) and the $scl (clock) pins.

  The $frequency specifies the default frequency for devices that are
    created with $device. Individual devices can have their frequency
    overwritten.

  If $pull-up is true, then the SDA and SCL pins are pulled up.
  The EPS32s pullups are *not* strong enough for high-speed I2C communication.
    Use external pull-up resistors if you need to communicate at high speeds.
    Many i2c modules have integrated built-in pull-up resistors, so this is typically not
    necessary.
  */
  constructor
      --sda/gpio.Pin
      --scl/gpio.Pin
      --frequency/int=DEFAULT-FREQUENCY
      --pull-up/bool=false:
    frequency_ = frequency
    resource_ = i2c-bus-create_ resource-group_ sda.num scl.num pull-up
    add-finalizer this:: close

  /**
  Scans all valid addresses.

  Returns the set of addresses that responded.

  Some addresses are reserved and are not scanned. See
    https://www.i2c-bus.org/addressing/.

  Waits at most $timeout-ms for a response on each address. If the bus is very
    slow, increase the timeout.
  */
  scan --timeout-ms/int=100 -> Set:
    result := {}
    for i := 0x08; i < 0x78; i++:
      if test i: result.add i
    return result

  /**
  Tests if the $address responds.

  Waits at most $timeout-ms for a response. If the bus is very slow, increase
    the timeout.
  */
  test address --timeout-ms/int=100 -> bool:
    return i2c-bus-probe_ resource_ address timeout-ms

  /**
  Closes this I2C bus.

  Releases the resources associated with this bus.
  */
  close -> none:
    if not resource_: return
    devices_.values.do: it.close
    devices_.clear
    i2c-bus-close_ resource_
    resource_ = null

  /**
  Creates the device connected on the $i2c-address.

  It is an error to connect a device on an address already in use.
    A device can be released with $Device.close.
  */
  device i2c-address/int --frequency/int -> Device:
    if devices_.contains i2c-address: throw "Device already connected"
    device := Device.init_ this i2c-address frequency
    devices_[i2c-address] = device
    return device


  /**
  Variant of $(device i2c-address --frequency) that uses the default frequency
    given to the bus at construction.
  */
  device i2c-address/int -> Device:
    return device i2c-address --frequency=frequency_

/**
Device connected using the I2C bus.

A device is connected on a specific I2C address that can be found in the data
  sheet of the device.
*/
class Device implements serial.Device:
  /** I2C address of the device. */
  address/int ::= ?

  bus_/Bus? := ?
  resource_ := ?
  registers_/Registers? := null

  constructor.init_ .bus_/Bus .address frequency/int:
    address-bit-size := 7
    timeout-us := 100_000
    disable-ack-check := false
    resource_ = i2c-device-create_ bus_.resource_ address-bit-size address frequency timeout-us disable-ack-check
    add-finalizer this:: close

  /**
  See $serial.Device.registers.

  Always returns the same object.
  */
  registers -> serial.Registers:
    if not registers_: registers_= Registers.init_ this
    return registers_

  with-failure-handling_ [block] [--on-failure]:
    e := catch:
      return block.call
    return on-failure.call e

  /**
  Writes the $bytes to the device.

  # Advanced
  The write operation is executed by sending:
  - a 'start',
  - the device's I2C address with the READ/WRITE bit set to WRITE. This is accomplished by
    shifting the I2C address by one and clearing the least-significant bit. The device must ack
  - the bytes.
  - the device must ack.
  - a 'stop'.
  */
  write bytes/ByteArray:
    i2c-device-write_ resource_ bytes

  /**
  Variant of $(write bytes).
  Calls the $failure block if the write fails.

  Deprecated. Use exception handling instead.
  */
  write bytes/ByteArray [failure]:
    with-failure-handling_ --on-failure=failure:
      write bytes

  /**
  Writes the $bytes to the device at the given $register.

  The $register value must satisfy 0 <= $register < 256.
  This is a convenience method and equivalent to prepending the $register byte to $bytes
    and then calling $(write bytes).
  */
  write-reg register/int bytes/ByteArray:
    if not 0 <= register < 256: throw "OUT_OF_RANGE"
    concatenated := ByteArray bytes.size + 1
    concatenated[0] = register
    concatenated.replace 1 bytes
    write concatenated

  /**
  Variant of $(write-reg register bytes).
  Calls the $failure block if the write fails.

  Deprecated. Use exception handling instead.
  */
  write-reg register/int bytes/ByteArray [failure]:
    with-failure-handling_ --on-failure=failure:
      write-reg register bytes

  /**
  Writes the $bytes to the device at the given $address.

  This is a convenience method and equivalent to prepending the $address bytes to $bytes
    and then calling $(write bytes).
  */
  write-address address/ByteArray bytes/ByteArray:
    concatenated := ByteArray address.size + bytes.size
    concatenated.replace 0 address
    concatenated.replace address.size bytes
    write concatenated

  /**
  Variant of $(write-address address bytes).
  Calls the $failure block if the write fails.

  Deprecated. Use exception handling instead.
  */
  write-address address/ByteArray bytes/ByteArray [failure]:
    with-failure-handling_ --on-failure=failure:
      write-address address bytes

  /**
  Reads $size bytes from the device.

  # Advanced
  The read operation is done as follows:
  - send a 'start',
  - send the device's I2C address with the READ/WRITE bit set to READ. This is accomplished by
    shifting the I2C address by one and setting the least-significant bit. The device must ack.
  - Read $size bytes, acking each byte except for the last, where receipt is confirmed with a 'nack'.
  - Finally, send a 'stop'.
  */
  read size/int -> ByteArray:
    result := ByteArray size
    i2c-device-read_ resource_ result size
    return result

  /**
  Variant of $(read size).

  Reads $size bytes into the given $buffer.
  */
  read-into buffer/ByteArray size/int=buffer.size -> none:
    if buffer.size < size: throw "OUT_OF_RANGE"
    i2c-device-read_ resource_ buffer size

  /**
  Variant of $(read size).
  Calls the $failure block if the read fails.

  Deprecated. Use exception handling instead.
  */
  read size/int [failure] -> ByteArray:
    return with-failure-handling_ --on-failure=failure:
      read size

  /**
  Reads $size bytes from the given $register.

  The $register value must satisfy 0 <= $register < 256.
  Equivalent to calling $read-address with a byte array containing
    the register value.
  */
  read-reg register/int size/int -> ByteArray:
    if not 0 <= register < 256: throw "OUT_OF_RANGE"
    bytes := #[register]
    return write-read bytes size

  /**
  Variant of $(read-reg register size).
  Calls the $failure block if the read fails.

  Deprecated. Use exception handling instead.
  */
  read-reg register/int size/int [failure] -> ByteArray:
    return with-failure-handling_ --on-failure=failure:
      read-reg register size

  /**
  Reads $size bytes from the given $address.
  */
  read-address address/ByteArray size/int -> ByteArray:
    return read-address address size: throw it

  /**
  Variant of $(read-address address size).
  Calls the $failure block if the operation fails.
  */
  read-address address/ByteArray size/int [failure] -> ByteArray:
    return with-failure-handling_ --on-failure=failure:
      read-address address size

  /**
  Writes the $tx-buffer to the device and reads $size bytes.


  # Advanced
  This operation is done as follows:
  - send a 'start',
  - send the device's I2C address with the READ/WRITE bit set to WRITE. This is accomplished by
    shifting the I2C address by one and clearing the least-significant bit. The device must ack.
  - send the tx-buffer, needing an 'ack' for each byte.
  - send another 'start'
  - send the device's I2C address with the READ/WRITE bit set to READ. This is accomplished by
    shifting the I2C address by one and setting the least-significant bit. The device must ack.
  - read $size bytes, sending an 'ack' for each byte except for the last, where
    receipt is confirmed with a 'nack'.
  - finally send a 'stop'.
  */
  write-read tx-buffer/io.Data size/int -> ByteArray:
    rx-buffer := ByteArray size
    i2c-device-write-read_ resource_ tx-buffer rx-buffer size
    return rx-buffer

  /**
  Variant of $(write-read tx-buffer size).
  Reads $size bytes into the given $rx-buffer.
  */
  write-read-into --tx-buffer/io.Data --rx-buffer/ByteArray size/int=rx-buffer.size -> none:
    if rx-buffer.size < size: throw "OUT_OF_RANGE"
    i2c-device-write-read_ resource_ tx-buffer rx-buffer size

  /** Closes this device and releases the I2C address. */
  close -> none:
    if not resource_: return
    i2c-device-close_ resource_
    resource_ = null
    bus_.devices_.remove address
    bus_ = null

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
  read-bytes reg count -> ByteArray:
    return device_.read-reg reg count

  /**
  See $super.

  Deprecated. Use exception handling instead.
  */
  read-bytes reg count [failure] -> ByteArray:
    e := catch:
      return read-bytes reg count
    return failure.call e

  /** See $super. */
  write-bytes reg bytes:
    data := ByteArray bytes.size + 1
    data[0] = reg
    data.replace 1 bytes
    device_.write data

resource-group_ ::= i2c-init_

i2c-init_:
  #primitive.i2c.init

i2c-bus-create_ resource-group sda scl pull-up:
  #primitive.i2c.bus-create

i2c-bus-close_ resource:
  #primitive.i2c.bus-close

i2c-bus-probe_ resource address/int timeout-ms/int:
  #primitive.i2c.bus-probe

i2c-bus-reset_ resource:
  #primitive.i2c.bus-reset

i2c-device-create_ bus address-length/int address/int frequency/int timeout-us/int disable-ack-check/bool:
  #primitive.i2c.device-create

i2c-device-close_ device:
  #primitive.i2c.device-close

i2c-device-read_ device buffer/ByteArray size/int:
  #primitive.i2c.device-read

i2c-device-write_ device buffer/io.Data:
  #primitive.i2c.device-write:
    return io.primitive-redo-io-data_ it buffer 0 buffer.byte-size: | bytes/ByteArray |
      i2c-device-write_ device bytes

i2c-device-write-read_ device tx-buffer/io.Data rx-buffer/ByteArray size/int:
  #primitive.i2c.device-write-read:
    return io.primitive-redo-io-data_ it tx-buffer 0 tx-buffer.byte-size: | tx-bytes/ByteArray |
      i2c-device-write-read_ device tx-bytes rx-buffer size
