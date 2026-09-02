// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import io
import serial
import monitor
import system

/** Default maximum transaction size for an SPI target. */
DEFAULT-TARGET-MAX-TRANSFER-SIZE ::= 4_092

/** Maximum transaction size for an SPI target without DMA. */
TARGET-NON-DMA-MAX-TRANSFER-SIZE ::= 64

/**
SPI is a serial communication bus able to address multiple devices along a main
  3-wire bus with an additional 1 wire per device.

To set up a SPI BUS:
```
import spi

MISO ::= 12
MOSI ::= 13
CLOCK ::= 14

main:
  bus := spi.Bus
    --miso=MISO
    --mosi=MOSI
    --clock=CLOCK
```

When communicating with a device, a unique chip-select (`cs`) pin is used to
  signal when the chip in question is addressed. In addition, it's important
  to not select a device frequency that exceeds the capabilities of the device.
  The maximum frequency can be found in the datasheet for the selected peripheral.

In case of the Bosch [BME280 sensor](https://cdn.sparkfun.com/assets/e/7/3/b/1/BME280_Datasheet.pdf),
  the maximum frequency is 10MHz:

```
  device := bus.device
    --cs=15
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
An ESP32 SPI target that exchanges one transaction at a time with a controller.

The $exchange method arms the peripheral before suspending the calling Toit
  task.

SPI does not define a standard register protocol. Protocols that interpret the
  first received bytes as commands or addresses should be built on top of this
  transaction API.

The ordinary ESP32 SPI target peripheral does not provide progress watermarks
  within one transaction. Large continuously clocked streams therefore need a
  separate chunked protocol in which the controller pauses between chunks or
  observes a ready signal.
*/
class Target:
  static READY-STATE_ ::= 1 << 0
  static DONE-STATE_ ::= 1 << 1

  resource_ := ?
  state_ := null
  mutex_/monitor.Mutex ::= monitor.Mutex
  close-mutex_/monitor.Mutex ::= monitor.Mutex
  max-transfer-size/int ::= ?
  exchange-in-flight_/bool := false
  closing_/bool := false
  when-armed-task_/Task? := null

  /**
  Constructs an SPI target.

  The $clock and $cs GPIOs are required. At least one of $mosi and $miso must
    be provided; pass null for an unused data direction. All pins are reserved
    until $close is called.

  $mode selects clock polarity and phase in the range 0 through 3.
  $transmit-lsb-first and $receive-lsb-first independently select the bit order
    used on MISO and MOSI, respectively.

  With $dma enabled, transactions use preallocated DMA-capable buffers and can
    be as large as $max-transfer-size. Without DMA, the ESP32 peripheral limits
    transactions to $TARGET-NON-DMA-MAX-TRANSFER-SIZE bytes.

  On the classic ESP32, target DMA cannot reliably receive and transmit at the
    same time. DMA reception is also unavailable in modes 1 and 3. Use
    non-DMA transactions of at most $TARGET-NON-DMA-MAX-TRANSFER-SIZE bytes,
    or configure only one data direction. These restrictions do not apply to
    newer ESP32 variants.

  Classic ESP32 target DMA commits received MOSI data in complete four-byte
    words. If the controller ends a transaction at another byte boundary, the
    trailing one to three bytes are discarded and are not returned by
    $exchange.
  */
  constructor
      --mosi/int?=null
      --miso/int?=null
      --clock/int
      --cs/int
      --mode/int=0
      --transmit-lsb-first/bool=false
      --receive-lsb-first/bool=false
      --.max-transfer-size/int=DEFAULT-TARGET-MAX-TRANSFER-SIZE
      --dma/bool=true:
    if not 0 <= mode <= 3: throw "INVALID_ARGUMENT"
    if not mosi and not miso: throw "INVALID_ARGUMENT"
    if max-transfer-size <= 0: throw "INVALID_ARGUMENT"
    if not dma and max-transfer-size > TARGET-NON-DMA-MAX-TRANSFER-SIZE:
      throw "INVALID_ARGUMENT"
    if dma
        and mosi
        and system.architecture == system.ARCHITECTURE-ESP32:
      if miso or (mode & 1) != 0: throw "INVALID_ARGUMENT"

    resource := spi-target-create_
        spi-target-resource-group_
        (mosi or -1)
        (miso or -1)
        clock
        cs
        mode
        transmit-lsb-first
        receive-lsb-first
        max-transfer-size
        dma
    resource_ = resource
    state/monitor.ResourceState_? := null
    initialized := false
    try:
      state = monitor.ResourceState_ spi-target-resource-group_ resource
      state_ = state
      add-finalizer this:: finalize_
      initialized = true
    finally:
      if not initialized:
        if state: state.dispose
        spi-target-close_ spi-target-resource-group_ resource
        resource_ = null

  /**
  Arms and waits for one full-duplex SPI transaction.

  Up to $receive-size bytes received on MOSI are returned. If the controller
    deasserts CS before clocking all requested bytes, the returned array is
    correspondingly shorter. The target sends $transmit on MISO and uses
    $fill-byte for any remaining clocks. The maximum of the transmit and
    receive sizes is the maximum number of bytes accepted for this transaction.

  If the task is interrupted or reaches its deadline after the peripheral is
    armed, the transaction is aborted and its native buffers are released
    before the exception is propagated.
  */
  exchange transmit/ByteArray=#[ ] -> ByteArray
      --receive-size/int=transmit.size
      --fill-byte/int=0xff:
    return exchange transmit
        --receive-size=receive-size
        --fill-byte=fill-byte
        --when-armed=: null

  /**
  Variant of $(exchange transmit) that calls $when-armed once the peripheral
    is armed.

  The $when-armed block runs before this method starts waiting for the
    controller. It can assert an application-level ready signal to tell the
    controller that it may start generating clocks. It must not call $close or
    recursively call $exchange; doing so throws `INVALID_STATE`.
  */
  exchange transmit/ByteArray=#[ ] -> ByteArray
      --receive-size/int=transmit.size
      --fill-byte/int=0xff
      [--when-armed]:
    if receive-size < 0: throw "OUT_OF_RANGE"
    if not 0 <= fill-byte <= 0xff: throw "OUT_OF_RANGE"
    transfer-size := transmit.size > receive-size ? transmit.size : receive-size
    if not 0 < transfer-size <= max-transfer-size: throw "OUT_OF_RANGE"
    if identical Task.current when-armed-task_: throw "INVALID_STATE"

    return mutex_.do:
      if not resource_ or closing_: throw "CLOSED"
      if exchange-in-flight_: throw "INVALID_STATE"

      // Allocate everything managed by the Toit heap before the native
      // transaction owns DMA buffers and can complete asynchronously.
      receive-buffer := ByteArray receive-size

      exchange-in-flight_ = true
      started := false
      finished := false
      try:
        state_.clear-state READY-STATE_ | DONE-STATE_
        spi-target-transfer-start_ resource_ transmit receive-size fill-byte
        started = true
        // The abort API operates on the mounted transaction. Mounting is
        // bounded and does not depend on controller clocks.
        critical-do --no-respect-deadline:
          state_.wait-for-state READY-STATE_
        when-armed-task_ = Task.current
        try:
          when-armed.call
        finally:
          when-armed-task_ = null
        state_.wait-for-state DONE-STATE_
        if closing_: throw "CLOSED"
        size := spi-target-transfer-finish_ resource_ receive-buffer false
        finished = true
        exchange-in-flight_ = false
        return receive-buffer.copy 0 size
      finally:
        if not finished:
          critical-do --no-respect-deadline:
            if started:
              // If natural completion won the race, abort returns false only
              // after its callback has finished. In either case, waiting for
              // DONE also drains a callback event that has not yet reached
              // ResourceState_.
              spi-target-transfer-finish_ resource_ receive-buffer true
              state_.wait-for-state DONE-STATE_
              spi-target-transfer-finish_ resource_ receive-buffer false
              state_.clear-state READY-STATE_ | DONE-STATE_
            exchange-in-flight_ = false

  /**
  Closes the target and releases its peripheral, pins, and native buffers.

  An exchange running in another task is aborted and throws `CLOSED`. Calling
    this method from that exchange's `when-armed` block is invalid.
  */
  close -> none:
    close-mutex_.do:
      if not resource_: return
      if identical Task.current when-armed-task_: throw "INVALID_STATE"
      closing_ = true
      if exchange-in-flight_:
        critical-do --no-respect-deadline:
          // The descriptor is mounted before READY is reported. Waiting here
          // also wakes an exchange that has not yet left its READY wait.
          state_.wait-for-state READY-STATE_
          spi-target-transfer-finish_ resource_ #[ ] true
          state_.wait-for-state DONE-STATE_
      mutex_.do:
        critical-do:
          state_.dispose
          spi-target-close_ spi-target-resource-group_ resource_
          resource_ = null
          remove-finalizer this

  finalize_ -> none:
    close

/**
An ESP32 SPI target that remains armed using native response and receive buffers.

Unlike $Target, this class does not wait for a Toit task to prepare each
  transaction. The peripheral is armed before the constructor returns and is
  re-armed from its completion callback. Received buffers are rotated instead
  of copied in that callback, so re-arming does not depend on the transaction
  size or on Toit task scheduling. This is useful for protocols whose
  controller cannot observe a separate ready signal. As with any ESP32 SPI
  target, the controller must still leave CS inactive long enough for the
  completion interrupt to re-arm the peripheral; a zero-width CS-inactive
  interval is not supported.

SPI does not define a register-address protocol. The response is therefore a
  plain byte buffer: each controller transaction starts at offset zero. Toit
  code can update that buffer using indexing, $read, and $write. Individual
  bytes are atomic, but a controller transaction concurrent with an update may
  observe the response one byte at a time.

Complete MOSI transactions are copied into a bounded native queue. This is not
  a streaming API: the controller must release CS at each buffer boundary.

On the classic ESP32 with DMA enabled, only complete four-byte words received
  on MOSI are queued. A trailing one to three bytes are discarded, matching
  the ESP-IDF target DMA restriction.

On configurations where ESP-IDF copies the response into hardware registers
  while arming, a response update can be too late for the next transaction. An
  update is guaranteed to be visible in the transaction after the next
  completed transaction, and can be visible sooner.

On the classic ESP32, SPI target interrupts are not placed in IRAM in the Toit
  firmware configuration. The target therefore cannot re-arm while flash
  operations disable the instruction cache. Controllers that may communicate
  during flash erase or write must use a separate ready signal or a newer ESP32
  variant.
*/
class BufferTarget:
  static RECEIVED-STATE_ ::= 1 << 2
  static STOPPED-STATE_ ::= 1 << 3
  static ARMED-STATE_ ::= 1 << 4

  resource_ := ?
  state_ := null
  close-mutex_/monitor.Mutex ::= monitor.Mutex
  receive-mutex_/monitor.Mutex ::= monitor.Mutex
  size/int ::= ?
  can-receive_/bool ::= ?
  can-transmit_/bool ::= ?

  /**
  Constructs an autonomous buffer-backed SPI target.

  $buffer-size is the maximum size of one controller transaction and must not
    exceed $DEFAULT-TARGET-MAX-TRANSFER-SIZE. $transmit is copied to the start
    of the native response buffer; remaining bytes are initialized to
    $fill-byte.

  $receive-queue-depth is the number of complete MOSI transactions retained
    until $receive consumes them. Further transactions are still answered and
    re-arm the peripheral, but their received data is discarded and counted by
    $dropped-receive-count.

  Pin, mode, bit-order, DMA, and classic ESP32 restrictions are the same as for
    $Target.
  */
  constructor
      transmit/ByteArray=#[ ]
      --mosi/int?=null
      --miso/int?=null
      --clock/int
      --cs/int
      --mode/int=0
      --transmit-lsb-first/bool=false
      --receive-lsb-first/bool=false
      --buffer-size/int=TARGET-NON-DMA-MAX-TRANSFER-SIZE
      --receive-queue-depth/int=4
      --fill-byte/int=0xff
      --dma/bool=true:
    if not 0 <= mode <= 3: throw "INVALID_ARGUMENT"
    if not mosi and not miso: throw "INVALID_ARGUMENT"
    if buffer-size <= 0 or buffer-size > DEFAULT-TARGET-MAX-TRANSFER-SIZE:
      throw "INVALID_ARGUMENT"
    if transmit.size > buffer-size: throw "INVALID_ARGUMENT"
    if receive-queue-depth <= 0: throw "INVALID_ARGUMENT"
    if not 0 <= fill-byte <= 0xff: throw "OUT_OF_RANGE"
    if not dma and buffer-size > TARGET-NON-DMA-MAX-TRANSFER-SIZE:
      throw "INVALID_ARGUMENT"
    if dma
        and mosi
        and system.architecture == system.ARCHITECTURE-ESP32:
      if miso or (mode & 1) != 0: throw "INVALID_ARGUMENT"

    response := ByteArray buffer-size
    response.fill fill-byte
    response.replace 0 transmit

    size = buffer-size
    can-receive_ = mosi != null
    can-transmit_ = miso != null
    resource := spi-buffer-target-create_
        spi-target-resource-group_
        (mosi or -1)
        (miso or -1)
        clock
        cs
        mode
        transmit-lsb-first
        receive-lsb-first
        receive-queue-depth
        response
        dma
    resource_ = resource
    state/monitor.ResourceState_? := null
    finalizer-added := false
    initialized := false
    try:
      state = monitor.ResourceState_ spi-target-resource-group_ resource
      state_ = state
      add-finalizer this:: close
      finalizer-added = true
      spi-buffer-target-arm_ resource
      critical-do --no-respect-deadline:
        state.wait-for-state ARMED-STATE_
      initialized = true
    finally:
      if not initialized:
        if state: state.dispose
        spi-buffer-target-close_ spi-target-resource-group_ resource false
        resource_ = null
        if finalizer-added: remove-finalizer this

  /** Returns the response byte stored at $index. */
  operator [] index/int -> int:
    if not resource_: throw "CLOSED"
    if not can-transmit_: throw "INVALID_STATE"
    return spi-buffer-target-get_ resource_ index

  /**
  Stores $value in the response buffer and returns it.

  See the class documentation for when the update becomes visible on MISO.
  */
  operator []= index/int value/int -> int:
    if not resource_: throw "CLOSED"
    if not can-transmit_: throw "INVALID_STATE"
    return spi-buffer-target-set_ resource_ index value

  /** Returns $count response bytes starting at $index. */
  read index/int count/int -> ByteArray:
    if not resource_: throw "CLOSED"
    if not can-transmit_: throw "INVALID_STATE"
    if count < 0: throw "OUT_OF_BOUNDS"
    result := ByteArray count
    spi-buffer-target-read_ resource_ index result
    return result

  /**
  Writes $bytes into the response buffer starting at $index.

  See the class documentation for when the update becomes visible on MISO.
  */
  write index/int bytes/ByteArray -> none:
    if not resource_: throw "CLOSED"
    if not can-transmit_: throw "INVALID_STATE"
    spi-buffer-target-write_ resource_ index bytes

  /**
  Waits for and returns the next complete MOSI transaction.

  If the controller released CS before $size bytes, the returned array is
    correspondingly shorter.
  */
  receive -> ByteArray:
    if not can-receive_: throw "INVALID_STATE"
    result := ByteArray size
    return receive-mutex_.do:
      while true:
        if not resource_: throw "CLOSED"
        received := spi-buffer-target-receive_ resource_ result
        if received >= 0:
          return received == result.size ? result : result.copy 0 received

        state_.clear-state RECEIVED-STATE_
        // Close the race between finding the queue empty and clearing the
        // state bit. A callback after this second check wakes the wait below.
        received = spi-buffer-target-receive_ resource_ result
        if received >= 0:
          return received == result.size ? result : result.copy 0 received
        state_.wait-for-state RECEIVED-STATE_

  /** Number of complete MOSI transactions discarded because the queue was full. */
  dropped-receive-count -> int:
    if not resource_: throw "CLOSED"
    return spi-buffer-target-dropped-receive-count_ resource_

  /** Stops the target and releases its peripheral, pins, and native buffers. */
  close -> none:
    close-mutex_.do:
      if not resource_: return
      critical-do --no-respect-deadline:
        wait-for-callback := spi-buffer-target-close_ spi-target-resource-group_ resource_ true
        if wait-for-callback: state_.wait-for-state STOPPED-STATE_
        state_.dispose
        spi-buffer-target-close_ spi-target-resource-group_ resource_ false
        resource_ = null
        remove-finalizer this

/**
Bus for communicating using SPI.

An SPI bus is constructed with 3 main wires for data transmission and a clock.
Each device on the bus is enabled with its own chip-select pin. See $Bus.device.
*/
class Bus:
  spi_ := ?
  devices_ := []
  closing_/bool := false
  reservation-active_/bool := false
  /**
  Mutex to serialize reservation attempts of multiple devices.
  See $Device.with-reserved-bus.

  ESP-IDF's blocking acquisition API does not support a finite timeout. Toit
    instead tries without waiting and yields between attempts; this mutex keeps
    those attempts serialized across devices on the bus.
  */
  reservation-mutex_/monitor.Mutex ::= monitor.Mutex

  /**
  Constructs a new SPI bus using the given $mosi, $miso, and $clock pins.

  The $mosi, $miso, and $clock are GPIO numbers. The bus reserves the pins and
    releases them again when the bus is closed.

  Passing a $gpio.Pin is deprecated; provide the integer GPIO number instead.
    The $gpio.Pin form will be removed in a future release.
  */
  // __TYPE-MIGRATION__ mosi: gpio.Pin. Deprecated. Provide an integer instead.
  // __TYPE-MIGRATION__ mosi: int?
  // __TYPE-MIGRATION__ miso: gpio.Pin. Deprecated. Provide an integer instead.
  // __TYPE-MIGRATION__ miso: int?
  // __TYPE-MIGRATION__ clock: gpio.Pin. Deprecated. Provide an integer instead.
  // __TYPE-MIGRATION__ clock: int
  constructor --mosi/any=null --miso/any=null --clock/any:
    spi_ = spi-init_
      gpio.to-pin-num_ mosi
      gpio.to-pin-num_ miso
      gpio.to-pin-num_ clock

  /** Closes this SPI bus and frees the associated resources. */
  close:
    if reservation-active_: throw "INVALID_STATE"
    reservation-mutex_.do:
      if not spi_: return
      closing_ = true
      devices := devices_.copy
      devices.do: | device/Device_ |
        device.close-under-reservation_
      devices_.clear
      critical-do:
        spi-close_ spi_
        spi_ = null

  /**
  Configures a device on this SPI bus.

  The device's clock speed is configured to the given $frequency. The given
    $frequency is only aspirational, and the actual frequency might
    be different. For example, the ESP32S3 seems to have a minimum frequency of
    100kHz.

  An optional $cs (chip select) and $dc (data/command) pin can be assigned
    for this device. They are GPIO numbers. The device reserves the pins and
    releases them again when the device is closed. If no $cs pin is provided,
    then the chip must be enabled in software (or hardware, tied to ground, if
    it's the only chip on the bus).

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

  Passing a $gpio.Pin as $cs or $dc is deprecated; provide the integer GPIO
    number instead. The $gpio.Pin form will be removed in a future release.

  $cs-setup-cycles requests that CS be active for the given number of SPI clock
    cycles before the first clock edge. ESP-IDF only supports this option for
    half-duplex transactions, except for a limited one-cycle case on the
    classic ESP32. $cs-hold-cycles keeps CS active after the last clock edge.
    Both values must be between 0 and 16.
  */
  // __TYPE-MIGRATION__ cs: gpio.Pin. Deprecated. Provide an integer instead.
  // __TYPE-MIGRATION__ cs: int?
  // __TYPE-MIGRATION__ dc: gpio.Pin. Deprecated. Provide an integer instead.
  // __TYPE-MIGRATION__ dc: int?
  device
      --cs/any=null
      --dc/any=null
      --frequency/int
      --mode/int=0
      --command-bits/int=0
      --address-bits/int=0
      --cs-setup-cycles/int=0
      --cs-hold-cycles/int=0
      -> Device:
    if mode < 0 or mode > 3: throw "Argument Error"
    if not 0 <= cs-setup-cycles <= 16: throw "OUT_OF_RANGE"
    if not 0 <= cs-hold-cycles <= 16: throw "OUT_OF_RANGE"
    cs-num := gpio.to-pin-num_ cs
    dc-num := gpio.to-pin-num_ dc
    // For a deprecated gpio.Pin the dc pin is configured here; for the new
    // integer API the primitive configures it as output.
    if dc is gpio.Pin: dc.configure --output

    return reservation-mutex_.do:
      if not spi_ or closing_: throw "CLOSED"
      d := spi-device_ spi_ cs-num dc-num command-bits address-bits frequency mode cs-setup-cycles cs-hold-cycles
      result := Device_.init_ this d
      devices_.add result
      return result

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

  /**
  See $serial.Device.registers.

  The $byte-size parameter specifies the size of the registers in bytes. For most
    I2C devices, this is 1, but 2 is common too. If the register size is greater than 1, then
    the $byte-order parameter specifies the byte order of the register address.

  Always returns the same object, unless the size of the registers changes or the register byte-order
    is not the same. The first allocation of the register cached; all subsequent *different* ones
    will create new objects.
  */
  registers --byte-size/int=1 --byte-order/io.ByteOrder=io.BIG-ENDIAN -> Registers

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
  See $serial.Device.registers.

  The $byte-size parameter specifies the size of the registers in bytes. For most
    I2C devices, this is 1, but 2 is common too.

  Always returns the same object, unless the size of the registers changes or the register byte-order
    is not the same. The first allocation of the register cached; all subsequent *different* ones
    will create new objects.
  */
  registers --byte-size/int=1 --byte-order/io.ByteOrder=io.BIG-ENDIAN -> Registers:
    if byte-size <= 0: throw "OUT_OF_RANGE"
    if not registers_:
      registers_= Registers.init_ this
          --byte-size=byte-size
          --byte-order=byte-order
    else if registers_.byte-size_ != byte-size or registers_.byte-order_ != byte-order:
      return Registers.init_ this
          --byte-size=byte-size
          --byte-order=byte-order
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
  static TRANSFER-DONE_ ::= 1 << 0

  spi_ := ?
  device_ := ?
  state_/monitor.ResourceState_ ::= ?
  transfer-mutex_/monitor.Mutex ::= monitor.Mutex
  owning-bus_/bool := false

  registers_/Registers? := null

  /** Deprecated. Use $Bus.device. */
  constructor .spi_ .device_:
    state_ = monitor.ResourceState_ spi_.spi_ device_
    add-finalizer this:: close

  constructor.init_ .spi_ .device_:
    state_ = monitor.ResourceState_ spi_.spi_ device_
    add-finalizer this:: close

  /** See $Device.close. */
  close:
    if owning-bus_: throw "INVALID_STATE"
    bus := spi_
    if not bus: return
    bus.reservation-mutex_.do:
      close-under-reservation_

  close-under-reservation_:
    transfer-mutex_.do:
      if not device_: return
      critical-do:
        state_.dispose
        spi-device-close_ spi_.spi_ device_
        device_ = null
        spi_.devices_.remove this
        spi_ = null
        remove-finalizer this

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
    transfer-mutex_.do:
      if not device_: throw "CLOSED"
      // Once queued, the ESP-IDF transaction cannot be canceled. Always wait
      // for completion and release its native buffers.
      critical-do --no-respect-deadline:
        state_.clear-state TRANSFER-DONE_
        spi-transfer-start_ device_ data command address from to read dc keep-cs-active
        state_.wait-for-state TRANSFER-DONE_
        // The post callback wakes this task slightly before ESP-IDF retires
        // the descriptor. Poll with a zero timeout until its return queue is
        // ready; no primitive waits for the driver.
        while not spi-transfer-finish_ device_ data from read: yield

  /** See $Device.with-reserved-bus. */
  with-reserved-bus [block]:
    if owning-bus_: throw "INVALID_STATE"
    bus := spi_
    if not bus: throw "CLOSED"
    bus.reservation-mutex_.do:
      if not device_ or bus.closing_: throw "CLOSED"
      while not spi-acquire-bus_ device_: yield
      owning-bus_ = true
      bus.reservation-active_ = true
      try:
        block.call
      finally:
        critical-do:
          owning-bus_ = false
          bus.reservation-active_ = false
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

  constructor.init_ .device_ --byte-size/int --byte-order/io.ByteOrder:
    super --byte-size=byte-size --byte-order=byte-order

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
    register-size := byte-size_
    data := ByteArray register-size + count
    byte-order_.put-uint data register-size 0 register
    data[0] = mask-reg_ (not msb-write_) data[0]
    transfer_ data --read
    return data.copy 1

  /**
  See $super.

  If `msb-write` is set (see $set-msb-write) modifies the register
    value so it has a high most-significant bit.
  */
  write-bytes reg/int bytes/ByteArray:
    register-size := byte-size_
    data := ByteArray bytes.size + register-size
    byte-order_.put-uint data register-size 0 reg
    data[0] = mask-reg_ msb-write_ data[0]
    data.replace register-size bytes
    transfer_ data

  /**
  Writes the given $bytes.

  Still sets the write/read bit.

  This function is needed because we support non-zero byte-sizes.
  Overrides the superclass implementation.
  */
  write-bytes_ bytes/ByteArray:
    bytes[0] = mask-reg_ msb-write_ bytes[0]
    transfer_ bytes

  transfer_ data --read=false:
    device_.transfer data --read=read

  mask-reg_ msb-high reg:
    return (msb-high ? reg | 0x80 : reg & 0x7f).to-int

spi-init_ mosi/int miso/int clock/int:
  #primitive.spi.init

spi-target-resource-group_ ::= spi-target-init_

spi-target-init_:
  #primitive.spi.target-init

spi-target-create_
    group
    mosi/int
    miso/int
    clock/int
    cs/int
    mode/int
    transmit-lsb-first/bool
    receive-lsb-first/bool
    max-transfer-size/int
    dma/bool:
  #primitive.spi.target-create

spi-target-close_ group target:
  #primitive.spi.target-close

spi-target-transfer-start_
    target
    transmit/ByteArray
    receive-size/int
    fill-byte/int:
  #primitive.spi.target-transfer-start

spi-target-transfer-finish_ target receive-buffer/ByteArray abort/bool:
  #primitive.spi.target-transfer-finish

spi-buffer-target-create_
    group
    mosi/int
    miso/int
    clock/int
    cs/int
    mode/int
    transmit-lsb-first/bool
    receive-lsb-first/bool
    receive-queue-depth/int
    response/ByteArray
    dma/bool:
  #primitive.spi.buffer-target-create

spi-buffer-target-arm_ target:
  #primitive.spi.buffer-target-arm

spi-buffer-target-close_ group target abort/bool:
  #primitive.spi.buffer-target-close

spi-buffer-target-get_ target index/int:
  #primitive.spi.buffer-target-get

spi-buffer-target-set_ target index/int value/int:
  #primitive.spi.buffer-target-set

spi-buffer-target-read_ target index/int result/ByteArray:
  #primitive.spi.buffer-target-read

spi-buffer-target-write_ target index/int bytes/ByteArray:
  #primitive.spi.buffer-target-write

spi-buffer-target-receive_ target result/ByteArray:
  #primitive.spi.buffer-target-receive

spi-buffer-target-dropped-receive-count_ target:
  #primitive.spi.buffer-target-dropped-receive-count

spi-close_ spi:
  #primitive.spi.close

spi-device_ spi cs/int dc/int command-bits/int address-bits/int frequency/int mode/int cs-setup-cycles/int cs-hold-cycles/int:
  #primitive.spi.device

spi-device-close_ spi device:
  #primitive.spi.device-close

spi-transfer-start_ device data/ByteArray command/int address/int from to read/bool dc/int keep-cs-active/bool:
  #primitive.spi.transfer-start

spi-transfer-finish_ device data/ByteArray from/int read/bool:
  #primitive.spi.transfer-finish

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
