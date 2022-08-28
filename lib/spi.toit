// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import serial
import monitor
import binary

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
  Mutex to serialize reservation attempts of multiple devices.
  See $Device.with_reserved_bus.

  When trying to acquire the bus, the ESP-IDF currently (as of 2022-07-19) does not allow to set a timeout.
    This means that the program would be stuck in the primitive. We thus use this mutex to avoid that
    situation.
  */
  reservation_mutex_/monitor.Mutex ::= monitor.Mutex

  /**
  Constructs a new SPI bus using the given $mosi, $miso, and $clock pins.
  */
  constructor --mosi/gpio.Pin?=null --miso/gpio.Pin?=null --clock/gpio.Pin:
    spi_ = spi_init_
      mosi ? mosi.num : -1
      miso ? miso.num : -1
      clock.num

  constructor.virtual_ .spi_:

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
      dc.configure --output

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

  When $keep_cs_active is true, then the chip select pin is kept active
    after the transfer. This functionality is only allowed when the
    bus is reserved for this device. See $with_reserved_bus.
  */
  transfer
      data/ByteArray
      --from/int=0
      --to/int=data.size
      --read/bool=false
      --dc/int=0
      --command/int=0
      --address/int=0
      --keep_cs_active/bool=false

  /**
  Reserves the bus for this device while executing the given $block.

  Starts by acquiring the bus. Once that's succeeded, executes the $block. Finally, releases
    the bus before returning.

  Reserving the bus can be useful in two contexts:
  1. The CS pin is controlled by the user. Since the hardware only supports a limited number of
    automatic CS pins, it might be necessary to set some CS pins by hand. This should be done
    after the bus has been reserved.
  2. When using the `--keep_cs_active` flag of the $transfer function, the bus must be reserved.
  */
  with_reserved_bus [block]

  /** Closes this SPI device and releases resources associated with it. */
  close

/** Device connected to an SPI bus. */
class Device_ implements Device:
  spi_/Bus := ?
  device_ := ?
  owning_bus_/bool := false

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
      --address/int=0
      --keep_cs_active/bool=false:
    if keep_cs_active and not owning_bus_: throw "INVALID_STATE"
    return spi_transfer_ device_ data command address from to read dc keep_cs_active

  /** See $Device.with_reserved_bus. */
  with_reserved_bus [block]:
    spi_.reservation_mutex_.do:
      spi_acquire_bus_ device_
      owning_bus_ = true
      try:
        block.call
      finally:
        owning_bus_ = false
        spi_release_bus_ device_

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

/**
Virtual emulation of a $Bus.
See $Bus.
*/
class VirtualBus extends Bus:

  /**
  Internal "transfer primitive" that will be called by devices
  instead of the spi_transfer_ primitive
  */
  bus_transfer_handler_ ::=?
  
  /**
  Construct a Virtual bus with a "primitive" transfer handler method
  $bus_transfer_handler_. The $bus_transfer_handler_ will be called
  by the virtual devices on the bus when they want to transfer data.
  */
  constructor .bus_transfer_handler_/Lambda=DEFAULT_TRANSFER_HANDLER_:
    super.virtual_ -1

  /**
  Default handler for virutal bus transfer.
  The transfer method calls this lambda  with the parameter 
  types specified here.
  The lambda must local-return a ByteArray.

  This implemententation prints the command, address 
  and data parameters that the Lambda was called with
  it also returns the recieved data if the read flag
  is true, otherwise it returns a ByteArray of the
  same size as the parameterized data, but filled with
  the value 0x00.
  */
  static DEFAULT_TRANSFER_HANDLER_ /Lambda ::= :: |
            dev_info/VirtualDeviceInfo_
            data/VirtualTransferData
            read/bool
          | 
        
        print "Cmd: $(%x data.command), Address: $(%x data.address), Data: $data.data, Read: $read"
        
        //Local return
        read? data.data : ByteArray data.data.size

  /** 
  See $super. 
  */
  device
      --cs/gpio.Pin?=null
      --dc/gpio.Pin?=null
      --frequency/int
      --mode/int=0
      --command_bits/int=0
      --address_bits/int=0
      -> Device:

    return VirtualDevice_.init_ 
      this 
      VirtualDeviceInfo_
        dc
        cs
        frequency
        mode
        command_bits
        address_bits

/**
Class to hold information about the instanciated VirtualDevice.
*/
class VirtualDeviceInfo_:
  dc/gpio.Pin?            ::= ?
  cs/gpio.Pin?            ::= ?
  frequency/int           ::= ?
  mode/int                ::= ?
  command_bits/int        ::= ?
  command_bits_mask/int   ::= ?
  address_bits/int        ::= ?
  address_bits_mask/int   ::= ?

  constructor .dc/gpio.Pin? .cs/gpio.Pin? .frequency/int .mode/int .command_bits/int .address_bits/int:
    if mode < 0 or mode > 3: throw "Argument Error"
    if command_bits < 0 or command_bits > 16: throw "Argument Error"
    if address_bits < 0 or address_bits > 64: throw "Argument Error"
    
    mask := 0
    command_bits.repeat:
      mask |= (1 << it)
    command_bits_mask = mask
    
    mask = 0
    address_bits.repeat:
      mask |= (1 << it)
    address_bits_mask = mask
    
/**
Compress the command, address and data from a $Device.transfer call
to a single object for use in a $Lambda.call. The data has to be 
compressed as the $Lambda.call only takes a maximum of 4 arguments.
*/
class VirtualTransferData:
  command/int     ::= ?
  address/int     ::= ?
  data/ByteArray  ::= ?

  constructor 
      device_settings_/VirtualDeviceInfo_
      command/int
      address/int
      .data/ByteArray:

    //Mask off command and address
    this.command = command & device_settings_.command_bits_mask
    this.address = address & device_settings_.address_bits_mask

/** Device connected to a Virtual SPI bus. */
class VirtualDevice_ extends Device_:

  /// Cs might be a $gpio.VirtualPin, so we keep the state here.
  curr_cs_logic_level/int  := 0 

  constructor.init_ spi_ device_:
    super.init_ spi_ device_

  /** See $super */
  close:
    device_ = null

  /** See $super */
  transfer
      data/ByteArray
      --from/int=0
      --to/int=data.size
      --read/bool=false
      --dc/int=0
      --command/int=0
      --address/int=0
      --keep_cs_active/bool=false:

    /** 
    Give the same user warning as $Device_.transfer for
    invalid use of the transfer $keep_cs_active flag.
    */
    if keep_cs_active and not owning_bus_: throw "INVALID_STATE"

    //Lock the bus to simulate that only one device may transfer at a time
    if not owning_bus_: 
      result := data
      this.with_reserved_bus:
        result = transfer 
          data
          --from=from
          --to=to
          --read=read
          --dc=dc
          --command=command
          --address=address
          --keep_cs_active=keep_cs_active
      return result

    

    dev_settings /VirtualDeviceInfo_ := device_ as VirtualDeviceInfo_
    
    /*
    Because a Lambdas can only be called with up to 4 arguments
    we handle dc here and compress command, address and data to
    one VirtualTransferData.
    */
    data_to_transmit := VirtualTransferData
      dev_settings
      command
      address
      data[from..to]

    /**
    Mirrors what the internal spi_pre_transer_callback does in
    the VM with a virtual pin.

    See line 183 in spi_esp32.cc (PRIMITIVE(device))
    */
    if dev_settings.dc: dev_settings.dc.set dc

    /**
    Cs is normally handled in the primitive for transfers, so
    simulate the Cs pin operation here.
    */
    if curr_cs_logic_level != 1:
      curr_cs_logic_level = 1
      if dev_settings.cs:
        dev_settings.cs.set 1

    /**
    Call the primitive of the $VirtualBus with the settings of this
    device, the data to transmit and the read flag specified in this
    transfer call.
    */
    result := (spi_ as VirtualBus).bus_transfer_handler_.call dev_settings data_to_transmit read

    /**
    Handle the keep_cs_active flag
    */
    if not keep_cs_active:
      curr_cs_logic_level = 0
      if dev_settings.cs:
        dev_settings.cs.set 0

    return result

  /** See $super. */
  with_reserved_bus [block]:
    spi_.reservation_mutex_.do:
      owning_bus_ = true
      try:
        block.call
      finally:
        owning_bus_ = false
    

spi_init_ mosi/int miso/int clock/int:
  #primitive.spi.init

spi_close_ spi:
  #primitive.spi.close

spi_device_ spi cs/int dc/int frequency/int mode/int command_bits/int address_bits/int:
  #primitive.spi.device

spi_device_close_ spi device:
  #primitive.spi.device_close

spi_transfer_ device data/ByteArray command/int address/int from to read/bool dc/int keep_cs_active/bool:
  #primitive.spi.transfer

spi_acquire_bus_ device:
  #primitive.spi.acquire_bus

spi_release_bus_ device:
  #primitive.spi.release_bus
