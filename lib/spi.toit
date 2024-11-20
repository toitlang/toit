// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import serial
import monitor

/**
SPI is a serial communication bus able to address multiple devices along a main 3-wire bus with an additional 1 wire per device.

To set up a SPI BUS:
```
import gpio
import spi

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

# Linux
On Linux, devices can be created directly using their path. There is no need to create
  a bus first.

Example:
```
import spi

main:
  device := spi.Device --path="/dev/spidev0.0" --frequency=10_000_000
  device.write #[0x01, 0x02, 0x03, 0x04]
  device.close
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
  Mutex to serialize reservation attempts of multiple devices.
  See $Device.with-reserved-bus.

  When trying to acquire the bus, the ESP-IDF currently (as of 2022-07-19) does not allow to set a timeout.
    This means that the program would be stuck in the primitive. We thus use this mutex to avoid that
    situation.
  */
  reservation-mutex_/monitor.Mutex ::= monitor.Mutex

  /**
  Constructs a new SPI bus using the given $mosi, $miso, and $clock pins.
  */
  constructor --mosi/gpio.Pin?=null --miso/gpio.Pin?=null --clock/gpio.Pin:
    spi_ = spi-init_
      mosi ? mosi.num : -1
      miso ? miso.num : -1
      clock.num

  /** Closes this SPI bus and frees the associated resources. */
  close:
    spi-close_ spi_

  /**
  Configures a device on this SPI bus.

  The device's clock speed is configured to the given $frequency.

  An optional $cs (chip select) and $dc (data/command) pin can be assigned
    for this device. If no $cs pin is provided, then the chip must be enabled
    in software (or hardware, tied to ground, if it's the only chip on the bus).

  The SPI $mode can further be configured in the range [0..3], defaulting
    to 0.

  Some SPI devices have an explicit command and/or address section that can be configured
    using $command-bits and $address-bits.

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
      --command-bits/int=0
      --address-bits/int=0
      -> Device:
    if mode < 0 or mode > 3: throw "Argument Error"
    cs-num := -1
    if cs: cs-num = cs.num
    dc-num := -1
    if dc:
      dc-num = dc.num
      dc.configure --output

    d := spi-device_ spi_ cs-num dc-num command-bits address-bits frequency mode
    return Device_.init_ this d

/**
A device connected with SPI.
*/
interface Device extends serial.Device:
  /**
  Constructs a device from the given $path.

  This function is only available on Linux.

  The given $frequency is only aspirational, and the actual frequency might
    be different. For example, the Raspberry Pi only supports a frequency range of
    3.814 kHz to 125 MHz. If the given $frequency is outside this range, it will be
    silently clamped to the nearest valid value.

  The $mode parameter configures the clock polarity and phase (CPOL and CPHA) for this device.
  The possible configurations are:
  - 0 (0b00): CPOL=0, CPHA=0
  - 1 (0b01): CPOL=0, CPHA=1
  - 2 (0b10): CPOL=1, CPHA=0
  - 3 (0b11): CPOL=1, CPHA=1

  # Pin numbers
  This constructor does not take any pin numbers. The pins are
    tied to the path, and configured outside. On the Raspberry Pi,
    look at `/boot/overlays/README` for more information. There, you
    can find options to move the SPI block, or to change/disable the
    chip select pins.
  */
  constructor --path/string --frequency/int --mode/int=0:
    return DevicePath_ --path=path --frequency=frequency --mode=mode

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

  When $keep-cs-active is true, then the chip select pin is kept active
    after the transfer. This functionality is only allowed when the
    bus is reserved for this device. See $with-reserved-bus.
  */
  transfer -> none
      data/ByteArray
      --from/int=0
      --to/int=data.size
      --read/bool=false
      --dc/int=0
      --command/int=0
      --address/int=0
      --keep-cs-active/bool=false

  /**
  Writes the $bytes to the device.

  If $keep-cs-active is true, then the chip select pin is kept active
    after the transfer. This functionality is only allowed when the
    bus is reserved for this device. See $with-reserved-bus.
  */
  write bytes/ByteArray --keep-cs-active/bool=false -> none

  /**
  Reserves the bus for this device while executing the given $block.

  If the system supports it, actively reserves the bus for this device. In that case,
    starts by acquiring the bus. Once that's succeeded, executes the $block. Finally, releases
    the bus before returning.

  On some systems, like Linux, it is not possible to reserve the bus. In that case, the
    programmer is responsible for managing the bus. This function then simply
    calls the given $block.

  Reserving the bus can be useful in two contexts:
  1. The CS pin is controlled by the user. Since the hardware only supports a limited number of
    automatic CS pins, it might be necessary to set some CS pins by hand. This should be done
    after the bus has been reserved.
  2. When using the `--keep-cs-active` flag of the $transfer function, the bus must be reserved.
  */
  with-reserved-bus [block]

  /** Closes this SPI device and releases resources associated with it. */
  close

abstract class DeviceBase_ implements Device:
  registers_/Registers? := null

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
  write bytes/ByteArray --keep-cs-active/bool=false:
    transfer bytes --keep-cs-active=keep-cs-active

  abstract close

  abstract transfer
      data/ByteArray
      --from/int=0
      --to/int=data.size
      --read/bool=false
      --dc/int=0
      --command/int=0
      --address/int=0
      --keep-cs-active/bool=false

  abstract with-reserved-bus [block]


/** Device connected to an SPI bus. */
class Device_ extends DeviceBase_:
  spi_/Bus := ?
  device_ := ?
  owning-bus_/bool := false

  registers_/Registers? := null

  /** Deprecated. Use $Bus.device. */
  constructor .spi_ .device_:

  constructor.init_ .spi_ .device_:

  /** See $Device.close. */
  close:
    if device_:
      spi-device-close_ spi_.spi_ device_
      device_ = null

  /** See $Device.transfer. */
  transfer
      data/ByteArray
      --from/int=0
      --to/int=data.size
      --read/bool=false
      --dc/int=0
      --command/int=0
      --address/int=0
      --keep-cs-active/bool=false:
    if keep-cs-active and not owning-bus_: throw "INVALID_STATE"
    return spi-transfer_ device_ data command address from to read dc keep-cs-active

  /** See $Device.with-reserved-bus. */
  with-reserved-bus [block]:
    spi_.reservation-mutex_.do:
      spi-acquire-bus_ device_
      owning-bus_ = true
      try:
        block.call
      finally:
        owning-bus_ = false
        spi-release-bus_ device_

class DevicePath_ extends DeviceBase_:
  static TRANSFER-DONE_ ::= 1 << 0

  static resource-group_ ::= spi-linux-init_

  resource_/ByteArray? := ?
  state_/monitor.ResourceState_
  // We can't enforce that the bus is reserved, but the `keep-cs-active` is only
  // allowed if the user requested to reserve the bus.
  reserved_/bool := false

  constructor --path/string --frequency/int --mode/int:
    resource_ = spi-linux-open_ resource-group_ path frequency mode
    state_ = monitor.ResourceState_ resource-group_ resource_
    add-finalizer this:: close

  close:
    resource := resource_
    if not resource: return
    critical-do:
      state_.dispose
      resource_ = null
      remove-finalizer this
      spi-linux-close_ resource

  transfer
      data/ByteArray
      --from/int=0
      --to/int=data.size
      --read/bool=false
      --dc/int=0
      --command/int=0
      --address/int=0
      --keep-cs-active/bool=false:
    if keep-cs-active and not reserved_: throw "INVALID_ARGUMENT"
    state_.clear-state TRANSFER-DONE_
    length := to - from
    delay_us := 0
    done := spi-linux-transfer-start_ resource_ data from length read delay_us keep-cs-active
    in/ByteArray? := null
    // There is no way to interrupt a started spi transfer. We have to wait for it to finish.
    critical-do --no-respect-deadline:
      if not done:
        state_.wait-for-state TRANSFER-DONE_
        if not resource_:
          // The device was closed while we were transfering.
          return
      // It is critical to call finish to release the buffer and reset the internal error state.
      in = spi-linux-transfer-finish_ resource_ read
    if read: data.replace from in


  with-reserved-bus [block]:
    if reserved_: throw "INVALID_STATE"
    try:
      reserved_ = true
      block.call
    finally:
      reserved_ = false

/** Register description of a device connected to an SPI bus. */
class Registers extends serial.Registers:
  device_/Device

  msb-write_ := false

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
  set-msb-write value/bool:
    msb-write_ = value

  /**
  See $super.

  If `msb-write` is set (see $set-msb-write) modifies the register
    value so it has a low most-significant bit.
  */
  read-bytes register/int count/int:
    data := ByteArray 1 + count
    data[0] = mask-reg_ (not msb-write_) register
    transfer_ data --read
    return data.copy 1

  /** See $super. */
  read-bytes register count [failure]:
    // TODO(anders): Can SPI fail?
    return read-bytes register count

  /**
  See $super.

  If `msb-write` is set (see $set-msb-write) modifies the register
    value so it has a high most-significant bit.
  */
  write-bytes reg bytes:
    data := ByteArray 1 + bytes.size
    data[0] = mask-reg_ msb-write_ reg
    data.replace 1 bytes
    transfer_ data

  transfer_ data --read=false:
    device_.transfer data --read=read

  mask-reg_ msb-high reg:
    return (msb-high ? reg | 0x80 : reg & 0x7f).to-int

spi-init_ mosi/int miso/int clock/int:
  #primitive.spi.init

spi-close_ spi:
  #primitive.spi.close

spi-device_ spi cs/int dc/int frequency/int mode/int command-bits/int address-bits/int:
  #primitive.spi.device

spi-device-close_ spi device:
  #primitive.spi.device-close

spi-transfer_ device data/ByteArray command/int address/int from to read/bool dc/int keep-cs-active/bool:
  #primitive.spi.transfer

spi-acquire-bus_ device:
  #primitive.spi.acquire-bus

spi-release-bus_ device:
  #primitive.spi.release-bus

spi-linux-init_:
  #primitive.spi_linux.init

spi-linux-open_ group/ByteArray path/string frequency/int mode/int:
  #primitive.spi_linux.open

spi-linux-transfer-start_ resource/ByteArray data/ByteArray from/int length/int is-read/bool delay_usecs/int keep-cs-active/bool:
  #primitive.spi_linux.transfer-start

spi-linux-transfer-finish_ resource/ByteArray was-read/bool:
  #primitive.spi_linux.transfer-finish

spi-linux-close_ resource_/ByteArray:
  #primitive.spi_linux.close
