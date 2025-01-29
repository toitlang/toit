// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import monitor show ResourceState_

import serial

/**
I2S Serial communication Bus.

An I2S bus can be either in master or slave mode. In master mode, the bus
  generates the clock and word select signals. In slave mode, the bus uses
  these signals as input.

Optionally, the peripheral can also generate the master clock (independently
  whether it is the master or not), which may be used for synchronization.
  The master clock is running at a multiple of the sample rate.

# ESP32 and ESP32S2
The ESP32 has two I2S peripherals, each of which can be configured in simplex (one way)
  or duplex (two way) mode. Only pins 0, 1, and 3 can be used as output for
  the master clock. The ESP32 does not support the master clock as input.

The ESP32S2 has one I2S peripheral. Only pins 18, 19, and 20 can be used as
  output for the master clock. The ESP32 does not support the master clock as input.

The channels on the peripheral are not independent. It's not possible to have two
  simplex channels on the same peripheral.

# Other ESP32 variants
The ESP32C3, and ESP32C6 have one I2S peripheral. There are no restrictions on
  which pins can be used for the master clock. The master clock can be used as
  input or output.

The ESP32S3 has two I2S peripherals. Only pins 18, 19, and 20 can be used as output
  for the master clock. Any pin can be used as master clock input.

The channels on the peripheral are independent. It's possible to have two simplex
  channels on the same peripheral. However, while the two channels have independent
  master clocks, only one master clock can be routed to a pin.

# Examples

```
import gpio
import i2s

// For this example, we just assume that this data should be
// written repeatedly to the I2S channel.
SOME-DATA ::= #[...]

main:
  tx := gpio.Pin 32
  sck := gpio.Pin 26
  ws := gpio.Pin 25
  // Since we only use the transmit channel, we call the variable
  // "channel" instead of "bus".
  channel := i2s.Bus
      --master=false
      --no-start
      --tx=tx
      --sck=sck
      --ws=ws
      --sample-rate=44100
      --bits-per-sample=16

  // Since we didn't start the bus, we can preload data.
  start-index := 0
  while true:
    preloaded := channel.preload SOME-DATA[start-index..]
    if preloaded == 0: break
    start-index += preloaded
    if start-index == SOME-DATA.size: start-index = 0

  channel.start

  channel.write SOME-DATA[start-index..]
  while true:
    channel.write SOME-DATA
```
*/


/**
I2S Serial communication Bus, primarily used to emit sound but has a wide
  range of usages.
*/
class Bus:
  i2s_ := ?
  state_/ResourceState_ ::= ?

  /**
  Philips format.

  The data signal has a one-bit shift compared to the word-select signal.
  That is, when the word-select signal switches, then there is still one
    bit of data left for the previous word.
  */
  static FORMAT-PHILIPS ::= 0

  /**
  MSB format.

  The data signal is aligned with the word-select signal.
  This is the same format as the $FORMAT-PHILIPS, but the bit-shift is
    not present.
  */
  static FORMAT-MSB ::= 1

  /**
  PCM short format.

  The data signal is shifted by one bit compared to the word-select signal (like Philips).
  The word-select signal is only active for one bit. The start of the word-select pulse
    is two bits before the data bit.
  */
  // TODO(florian): verify this. The documentation has different diagrams for this
  // format depending on which mode is used.
  static FORMAT-PCM-SHORT ::= 2

  /**
  A slot configuration for stereo.

  The left and right slots are interleaved in the data stream.
  The data in the buffers and on the wire is the same.

  For example:
  ```
  Data:
    0x0001  | 0x0002  | 0x0003  | 0x0004  | ...

  Wire:
    WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------| ...
    0x0001    0x0002    0x0003    0x0004
  ```
  */
  static SLOTS-STEREO-BOTH ::= 0
  /**
  A slot configuration for transmitting the left data of the buffer.

  # ESP32 and ESP32S2
  Sends the left data to both slots.

  ```
  Data:
    0x0001  | 0x0002  | 0x0003  | 0x0004  | ...

  Wire:
    WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------| ...
    0x0001    0x0001    0x0003    0x0003
  ```

  # Other ESP32 variants
  Sends the left data to the left slot and 0s to the right slot.

  ```
  Data:
    0x0001  | 0x0002  | 0x0003  | 0x0004  | ...

  Wire:
    WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------| ...
    0x0001    0x0000    0x0003    0x0000
  ```
  */
  static SLOTS-STEREO-LEFT ::= 1
  /**
  A slot configuration for transmitting the right data of the buffer.

  # ESP32 and ESP32S2
  Sends the right data to both slots.

  ```
  Data:
    0x0001  | 0x0002  | 0x0003  | 0x0004  | ...

  Wire:
    WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------| ...
    0x0002    0x0002    0x0004    0x0004
  ```

  # Other ESP32 variants
  Sends the right data to the right slot and 0s to the left slot.

  ```
  Data:
    0x0001  | 0x0002  | 0x0003  | 0x0004  | ...

  Wire:
    WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------| ...
    0x0000    0x0002    0x0000    0x0004
  ```
  */
  static SLOTS-STEREO-RIGHT ::= 2
  /**
  A slot configuration for transmitting the same data to both slots.

  # ESP32
  In 8-bit and 24-bit mode, the data must be padded to 16/32 bits.

  For 16-bit (also the padded 8-bit), every two bytes are swapped.

  ```
  Data:
    0x0001  | 0x0002  | 0x0003  | 0x0004  | ...

  Wire:
    WS-low  | WS-high | WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------|---------|---------| ...
    0x0002  | 0x0002  | 0x0001  | 0x0001  | 0x0004  | 0x0004  | ...
  ```

  # Other ESP32 variants
  The data is sent to both slots.
  No reordering is done.

  ```
  Data:
    0x0001  | 0x0002  | 0x0003  | 0x0004  | ...

  Wire:
    WS-low  | WS-high | WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------|---------|---------| ...
    0x0001  | 0x0001  | 0x0002  | 0x0002  | 0x0003  | 0x0003  | ...
  ```
  */
  static SLOTS-MONO-BOTH ::= 3
  /**
  A slot configuration for mono left.

  When writing, emits the data to the left buffer.
  When receiving, only collects the left slot.

  # ESP32
  ## Output
  In 8-bit and 24-bit mode, the data must be padded to 16/32 bits.

  For 16-bit (also the padded 8-bit), every two bytes are swapped.

  ```
  Data:
    0x0001  | 0x0002  | 0x0003  | 0x0004  | ...

  Wire:
    WS-low  | WS-high | WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------|---------|---------| ...
    0x0002  | 0x0000  | 0x0001  | 0x0000  | 0x0004  | 0x0000  | ...
  ```

  ## Input
  Only collects the left slot.

  For 16-bit (also the padded 8-bit), every two bytes are swapped.

  ```
  Wire:
    WS-low  | WS-high | WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------|---------|---------| ...
    0x0001  | 0x0002  | 0x0003  | 0x0004  | 0x0005  | 0x0006  | ...

  Data:
    0x0001 | 0x0000 | 0x0005 | 0x0003 | 0x0009 | 0x0007 | ...
  ```

  # Other ESP32 variants
  ## Output
  The data is sent to the left slot and 0s to the right slot.

  ```
  Data:
    0x0001  | 0x0002  | 0x0003  | 0x0004  | ...

  Wire:
    WS-low  | WS-high | WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------|---------|---------| ...
    0x0001  | 0x0000  | 0x0002  | 0x0000  | 0x0003  | 0x0000  | ...
  ```

  ## Input
  Only collects the left slot.

  ```
  Wire:
    WS-low  | WS-high | WS-low  | WS-high | WS-low  | WS-high | ...
    --------|---------|---------|---------|---------|---------| ...
    0x0001  | 0x0002  | 0x0003  | 0x0004  | 0x0005  | 0x0006  | ...

  Data:
    0x0001 | 0x0003 | 0x0005 | 0x0007 | 0x0009 | ...
  ```
  */
  static SLOTS-MONO-LEFT ::= 4
  /**
  A slot configuration for mono right.

  When writing, emits the data to the right buffer.
  When receiving, only collects the right slot.

  See $SLOTS-MONO-LEFT.
  */
  static SLOTS-MONO-RIGHT ::= 5


  /**
  Constructs an I2S channel as input.

  For typical I2S setups, the $rx pin, a clock ($sck), and a word select ($ws)
    pins are required. The master clock ($mclk) is optional.

  If $master is true, then I2S peripheral runs as master. As master, the
    $sck, $ws, and $mclk pins are outputs. As slave, they are inputs.

  The $sample-rate is the rate at which samples are written.
  The $bits-per-sample is the width of each sample. It can be either 8, 16, 24 or 32.
    For 8 and 24 bits see the note on the ESP32 below.

  If a $mclk pin is provide, then the master clock is emitted/read from that pin.
    Some ESP variants have restrictions on which pins can be used as output.
    Some variants don't support the master clock as input. Note that the $mclk
    can be an output, even if the bus is in slave mode.
  The $mclk-multiplier is the multiplier of the $sample-rate to be used for the
    master clock. It should be one of the 128, 256, 384, 512, 576, 768, 1024,
    or 1152. If none is given, it defaults to 384 for 24 bits per sample and
    256 otherwise. If the bits-per-sample is 24 bits, then the multiplier must
    be a multiple of 3.
  The $mclk-multiplier is mostly revelant if $mclk is provided, but can also be
    used to allow slower sample-rates: a higher multiplier allows for a slower
    frequency.
  If the $mclk-external-frequency is set to a value and $mclk was provided, then
    the master clock is read from the $mclk pin. This is only supported on some ESP32
    variants. The $mclk-external-frequency value must be higher than the clock
    frequency (sample-rate * bits-per-sample * 2).

  If the $start flag is true (the default) then the bus is started immediately.
    Set the flag to false if you want to $preload data before starting the bus.

  The $slots must be one of $SLOTS-STEREO-BOTH, $SLOTS-MONO-LEFT, $SLOTS-MONO-RIGHT.
    one slot
  the bus is in stereo mode. In stereo mode,
    the left and right slots are interleaved in the data stream. The

  The $format must be one of $FORMAT-MSB, $FORMAT-PHILIPS, $FORMAT-PCM-SHORT.

  The $invert-sck, $invert-ws, $invert-mclk flags can be used to
    invert the signals.

  # Esp32
  On the ESP32, the buffer needs to be padded for 8 and 24 bits samples. That
    is, for $bits-per-sample equal to 8 each sample should be 16 bits, where
    only the highest 8 bits are used. For 24 bits, each sample should be 32
    bits, where only the highest 24 bits are used. The same is true when data
    is read from the I2S bus.
  */
  constructor
      --master/bool
      --rx/gpio.Pin
      --sck/gpio.Pin?=null
      --ws/gpio.Pin?=null
      --mclk/gpio.Pin?=null
      --invert-sck/bool=false
      --invert-ws/bool=false
      --invert-mclk/bool=false
      --mclk-external-frequency/int?=null
      --sample-rate/int
      --bits-per-sample/int
      --mclk-multiplier/int?=null
      --format/int=FORMAT-PHILIPS
      --slots=SLOTS-STEREO-BOTH
      --start/bool=true:
    if slots != SLOTS-STEREO-BOTH and slots != SLOTS-MONO-LEFT and slots != SLOTS-MONO-RIGHT:
      throw "INVALID_ARGUMENT"
    return Bus.private_
        --master=master
        --rx=rx
        --tx=null
        --sck=sck
        --ws=ws
        --mclk=mclk
        --invert-sck=invert-sck
        --invert-ws=invert-ws
        --invert-mclk=invert-mclk
        --mclk-external-frequency=mclk-external-frequency
        --sample-rate=sample-rate
        --bits-per-sample=bits-per-sample
        --mclk-multiplier=mclk-multiplier
        --format=format
        --slots=slots
        --start=start

  /**
  Variant of $(constructor --master --rx --sample-rate --bits-per-sample)
    that creates a bus for output.

  The $slots must be one of $SLOTS-STEREO-BOTH, $SLOTS-STEREO-LEFT, $SLOTS-STEREO-RIGHT,
    $SLOTS-MONO-BOTH, $SLOTS-MONO-LEFT, or $SLOTS-MONO-RIGHT.
  */
  constructor
      --master/bool
      --tx/gpio.Pin
      --sck/gpio.Pin?=null
      --ws/gpio.Pin?=null
      --mclk/gpio.Pin?=null
      --invert-sck/bool=false
      --invert-ws/bool=false
      --invert-mclk/bool=false
      --mclk-external-frequency/int?=null
      --sample-rate/int
      --bits-per-sample/int
      --mclk-multiplier/int?=null
      --format/int=FORMAT-PHILIPS
      --slots/int=SLOTS-STEREO-BOTH
      --start/bool=true:
    return Bus.private_
        --master=master
        --rx=null
        --tx=tx
        --sck=sck
        --ws=ws
        --mclk=mclk
        --invert-sck=invert-sck
        --invert-ws=invert-ws
        --invert-mclk=invert-mclk
        --sample-rate=sample-rate
        --bits-per-sample=bits-per-sample
        --mclk-multiplier=mclk-multiplier
        --mclk-external-frequency=mclk-external-frequency
        --format=format
        --slots=slots
        --start=start

  /**
  Variant of $(constructor --master --rx --sample-rate --bits-per-sample)
    that creates a bus for input and output.

  In this configuration the $sck, $ws, and $mclk pins are shared between the
    input and output.
  */
  constructor.duplex
      --master/bool
      --rx/gpio.Pin
      --tx/gpio.Pin
      --sck/gpio.Pin?=null
      --ws/gpio.Pin?=null
      --mclk/gpio.Pin?=null
      --invert-sck/bool=false
      --invert-ws/bool=false
      --invert-mclk/bool=false
      --mclk-external-frequency/int?=null
      --sample-rate/int
      --bits-per-sample/int
      --mclk-multiplier/int?=null
      --format/int=FORMAT-PHILIPS
      --stereo/bool=true
      --slots/int=SLOTS-STEREO-BOTH
      --start/bool=true:
    return Bus.private_
        --master=master
        --rx=rx
        --tx=tx
        --sck=sck
        --ws=ws
        --mclk=mclk
        --invert-sck=invert-sck
        --invert-ws=invert-ws
        --invert-mclk=invert-mclk
        --sample-rate=sample-rate
        --bits-per-sample=bits-per-sample
        --mclk-multiplier=mclk-multiplier
        --mclk-external-frequency=mclk-external-frequency
        --format=format
        --slots=slots
        --start=start

  constructor.private_
      --master/bool
      --sck/gpio.Pin?
      --ws/gpio.Pin?
      --tx/gpio.Pin?
      --rx/gpio.Pin?
      --mclk/gpio.Pin?
      --invert-sck/bool
      --invert-ws/bool
      --invert-mclk/bool
      --mclk-external-frequency/int?
      --sample-rate/int
      --bits-per-sample/int
      --mclk-multiplier/int?
      --format/int
      --slots/int
      --start/bool:
    if mclk-multiplier:
      if bits-per-sample == 24 and mclk-multiplier % 3 != 0: throw "INVALID_ARGUMENT"
      if mclk-multiplier != 128 and mclk-multiplier != 256 and mclk-multiplier != 384
          and mclk-multiplier != 512 and mclk-multiplier != 576 and mclk-multiplier != 768
          and mclk-multiplier != 1024 and mclk-multiplier != 1152:
        throw "INVALID_ARGUMENT"
    else:
      mclk-multiplier = bits-per-sample == 24 ? 384 : 256
    if bits-per-sample != 8 and bits-per-sample != 16 and bits-per-sample != 24 and bits-per-sample != 32:
      throw "INVALID_ARGUMENT"
    if not tx and not rx:
      // We could support this, but it is not clear what the use case would be.
      throw "INVALID_ARGUMENT"
    if slots != SLOTS-STEREO-BOTH and slots != SLOTS-STEREO-LEFT and slots != SLOTS-STEREO-RIGHT
        and slots != SLOTS-MONO-BOTH and slots != SLOTS-MONO-LEFT and slots != SLOTS-MONO-RIGHT:
      throw "INVALID_ARGUMENT"
    if format != FORMAT-PHILIPS and format != FORMAT-MSB and format != FORMAT-PCM-SHORT:
      throw "INVALID_ARGUMENT"

    rx-pin := rx ? rx.num : -1
    tx-pin := tx ? tx.num : -1
    sck-pin := sck ? sck.num : -1
    ws-pin := ws ? ws.num : -1
    mclk-pin := mclk ? mclk.num : -1
    if sck-pin != -1 and invert-sck: sck-pin |= 0x1_0000
    if ws-pin != -1 and invert-ws: ws-pin |= 0x1_0000
    if mclk-pin != -1 and invert-mclk: mclk-pin |= 0x1_0000
    if mclk-pin != -1 and mclk-external-frequency:
      if mclk-external-frequency < sample-rate * bits-per-sample * 2:
        throw "INVALID_ARGUMENT"
    if not mclk-external-frequency: mclk-external-frequency = -1
    i2s_ = i2s-create_
        resource-group_
        sck-pin
        ws-pin
        tx-pin
        rx-pin
        mclk-pin
        sample-rate
        bits-per-sample
        master
        mclk-multiplier
        format
        slots
        mclk-external-frequency
    state_ = ResourceState_ resource-group_ i2s_

    if start: this.start

  /**
  Deprecated.

  $is-master has been renamed to '--master' and is now mandatory.
  $use-apll is no longer supported.
  $buffer-size is no longer supported.
  */
  constructor
      --sck/gpio.Pin?=null
      --ws/gpio.Pin?=null
      --tx/gpio.Pin?=null
      --rx/gpio.Pin?=null
      --mclk/gpio.Pin?=null
      --sample-rate/int
      --bits-per-sample/int
      --is-master/bool=true
      --mclk-multiplier/int=256
      --use-apll/bool=false
      --buffer-size/int=-1:
    return Bus.private_
        --master=is-master
        --sck=sck
        --ws=ws
        --tx=tx
        --rx=rx
        --mclk=mclk
        --invert-sck=false
        --invert-ws=false
        --invert-mclk=false
        --mclk-external-frequency=null
        --sample-rate=sample-rate
        --bits-per-sample=bits-per-sample
        --mclk-multiplier=mclk-multiplier
        --slots=SLOTS-STEREO-BOTH
        --format=FORMAT-PHILIPS
        --start=true

  /**
  Number of encountered errors.

  If the program wasn't fast enough to read or write the buffers, then
    a buffer overrun or underrun might occur. This is counted as an error.
  */
  errors -> int:
    if not i2s_: throw "CLOSED"
    return i2s-errors_ i2s_

  /**
  Starts the bus.

  Usually the bus is started automatically when it is created. However, if
    the bus was created with the $start flag set to false, then this method
    must be called to start the bus.

  When a bus was constructed but not started yet, then the master clock is
    running, but the other signals are not. Specifically, in master mode,
    there is no clock, word select or data being transmitted.

  The bus must not already be started.

  There is no need to $stop a bus. Calling $close is enough.
  */
  start -> none:
    if not i2s_: throw "CLOSED"
    i2s-start_ i2s_

  /**
  Stops the bus.

  It's rare that you need to stop the bus. Usually, you just close it.

  The bus must be started.
  */
  stop -> none:
    if not i2s_: throw "CLOSED"
    i2s-stop_ i2s_

  /**
  Preloads data to the I2S bus.

  The channel must have a transmit channel.

  The bus must be stopped.

  Returns the number of bytes that were preloaded.
  */
  preload buffer/ByteArray -> int:
    if not i2s_: throw "CLOSED"
    return i2s-preload_ i2s_ buffer

  /**
  Writes bytes to the I2S bus.

  This method blocks until all data has been written.
  */
  write bytes/ByteArray -> int:
    if not i2s_: throw "CLOSED"

    total-size := bytes.size
    written := 0
    while written != total-size:
      written += try-write bytes[written..]
    return total-size

  /**
  Writes bytes to the I2S bus.

  This method blocks until some data has been written.

  Returns the number of bytes written.
  */
  try-write bytes/ByteArray -> int:
    should-yield := true
    while true:
      if not i2s_: throw "CLOSED"

      state_.clear-state WRITE-STATE_ | ERROR-STATE_

      written := i2s-write_ i2s_ bytes
      if should-yield: yield
      if written != 0: return written
      // Try again without waiting for signals.
      written = i2s-write_ i2s_ bytes
      if written != 0: return written

      state := state_.wait-for-state WRITE-STATE_ | ERROR-STATE_
      should-yield = false

  /**
  Read bytes from the I2S bus.

  This methods blocks until data is available.
  */
  read -> ByteArray?:
    result := ByteArray 496
    count := read result
    return result[..count]

  /**
  Read bytes from the I2S bus to a buffer.

  This methods blocks until data is available.
  */
  read buffer/ByteArray -> int?:
    should-yield := true
    while true:
      if not i2s_: throw "CLOSED"

      read := i2s-read-to-buffer_ i2s_ buffer
      if should-yield:
        yield
        should-yield = false
      if read > 0: return read
      state := state_.wait-for-state READ-STATE_ | ERROR-STATE_
      state_.clear-state READ-STATE_ | ERROR-STATE_

  /**
  Close the I2S bus and releases resources associated to it.
  */
  close:
    if not i2s_: return
    critical-do:
      state_.dispose
      i2s-close_ resource-group_ i2s_
      i2s_ = null

resource-group_ ::= i2s-init_

READ-STATE_  ::= 1 << 0
WRITE-STATE_ ::= 1 << 1
ERROR-STATE_ ::= 1 << 2


i2s-init_:
  #primitive.i2s.init

i2s-create_
    resource-group
    sck-pin
    ws-pin
    tx-pin
    rx-pin
    mclk-pin
    sample-rate
    bits-per-sample
    is-master
    mclk-multiplier
    format
    slots
    mclk-external-frequency:
  #primitive.i2s.create

i2s-start_ i2s:
  #primitive.i2s.start

i2s-stop_ i2s:
  #primitive.i2s.stop

i2s-preload_ i2s buffer:
  #primitive.i2s.preload

i2s-close_ resource-group i2s:
  #primitive.i2s.close

i2s-write_ i2s bytes -> int:
  #primitive.i2s.write

i2s-read-to-buffer_ i2s buffer:
  #primitive.i2s.read-to-buffer

i2s-errors_ i2s -> int:
  #primitive.i2s.errors
