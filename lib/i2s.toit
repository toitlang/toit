// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import monitor show ResourceState_

/**
I2S Serial communication Bus.

An I2S bus can be either in master or slave mode. In master mode, the bus
  generates the clock and word-select signals. In slave mode, the bus uses
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
      --tx=tx
      --sck=sck
      --ws=ws

  channel.configure
      --sample-rate=44100
      --bits-per-sample=16

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

  i2s_ := ?
  state_/ResourceState_ ::= ?

  mclk_/gpio.Pin?
  sck_/gpio.Pin?
  ws_/gpio.Pin?
  tx_/gpio.Pin?
  rx_/gpio.Pin?

  invert-mclk_/bool
  invert-sck_/bool
  invert-ws_/bool

  is-master/bool

  /**
  Constructs an I2S channel.

  For typical I2S setups, the $rx/$tx pin, a clock ($sck), and a word-select ($ws)
    pins are required. The master clock ($mclk) is optional.

  If $master is true, then I2S peripheral runs as master. As master, the
    $sck, $ws, and $mclk pins are outputs. As slave, they are inputs.

  If a $mclk pin is provide, then the master clock is emitted/read from that pin.
    Some ESP variants have restrictions on which pins can be used as output.
    Some variants don't support the master clock as input. Note that the $mclk
    can be an output, even if the bus is in slave mode.

  The $invert-sck, $invert-ws, $invert-mclk flags can be used to
    invert the signals.
  */
  constructor
      --master/bool
      --mclk/gpio.Pin?=null
      --ws/gpio.Pin?
      --sck/gpio.Pin?
      --tx/gpio.Pin?=null
      --rx/gpio.Pin?=null
      --invert-mclk/bool=false
      --invert-ws/bool=false
      --invert-sck/bool=false:
    if not tx and not rx:
      // We could support this, but it is not clear what the use case would be.
      throw "INVALID_ARGUMENT"

    is-master = master

    sck_ = sck
    ws_ = ws
    tx_ = tx
    rx_ = rx
    mclk_ = mclk

    invert-mclk_ = invert-mclk
    invert-sck_ = invert-sck
    invert-ws_ = invert-ws

    tx-pin := tx ? tx.num : -1
    rx-pin := rx ? rx.num : -1
    mclk-pin := mclk ? mclk.num : -1
    sck-pin := sck ? sck.num : -1
    ws-pin := ws ? ws.num : -1

    i2s_ = i2s-create_
        resource-group_
        tx-pin
        rx-pin
        master
    state_ = ResourceState_ resource-group_ i2s_

  /**
  Configures the channel.

  A channel can only be configured when it is not running ($start).

  The $sample-rate is the rate at which samples are written.
  The $bits-per-sample is the width of each sample. It can be either 8, 16, 24, or 32.
    For 8 and 24 bits see the note on the ESP32 below.

  The $mclk-multiplier is the multiplier of the $sample-rate to be used for the
    master clock. It should be one of the 128, 256, 384, 512, 576, 768, 1024,
    or 1152. If none is given, it defaults to 384 for 24 bits per sample and
    256 otherwise. If the bits-per-sample is 24 bits, then the multiplier must
    be a multiple of 3.
  The $mclk-multiplier is mostly revelant if a mclk pin was provided, but can
    also be used to allow slower sample-rates: a higher multiplier allows for
    a slower frequency.
  If the $mclk-external-frequency is set to a value and a mclk pin was provided, then
    the master clock is read from the mclk pin. This is only supported on some ESP32
    variants. The $mclk-external-frequency value must be higher than the clock
    frequency (sample-rate * bits-per-sample * 2).

  The $slots-in must be one of $SLOTS-STEREO-BOTH, $SLOTS-MONO-LEFT,
    $SLOTS-MONO-RIGHT.
  The $slots-out must be one of $SLOTS-STEREO-BOTH, $SLOTS-STEREO-LEFT
    (data is stereo, but only emit the left channel),
    $SLOTS-STEREO-RIGHT, $SLOTS-MONO-BOTH (data is mono, and should be sent to
    left and right), $SLOTS-MONO-LEFT, or $SLOTS-MONO-RIGHT.

  The $format must be one of $FORMAT-MSB, $FORMAT-PHILIPS, $FORMAT-PCM-SHORT.
  */
  configure
      --mclk-external-frequency/int?=null
      --mclk-multiplier/int?=null
      --sample-rate/int
      --bits-per-sample/int
      --format/int=FORMAT-PHILIPS
      --slots-in/int
      --slots-out/int:
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
    if slots-in != SLOTS-STEREO-BOTH and slots-in != SLOTS-MONO-LEFT and slots-in != SLOTS-MONO-RIGHT:
      throw "INVALID_ARGUMENT"
    if slots-out != SLOTS-STEREO-BOTH and slots-out != SLOTS-STEREO-LEFT and slots-out != SLOTS-STEREO-RIGHT
        and slots-out != SLOTS-MONO-BOTH and slots-out != SLOTS-MONO-LEFT and slots-out != SLOTS-MONO-RIGHT:
      throw "INVALID_ARGUMENT"
    if format != FORMAT-PHILIPS and format != FORMAT-MSB and format != FORMAT-PCM-SHORT:
      throw "INVALID_ARGUMENT"

    tx-pin := tx_ ? tx_.num : -1
    rx-pin := rx_ ? rx_.num : -1
    mclk-pin := mclk_ ? mclk_.num : -1
    sck-pin := sck_ ? sck_.num : -1
    ws-pin := ws_ ? ws_.num : -1
    if mclk-pin != -1 and invert-mclk_: mclk-pin |= 0x1_0000
    if sck-pin != -1 and invert-sck_: sck-pin |= 0x1_0000
    if ws-pin != -1 and invert-ws_: ws-pin |= 0x1_0000

    if mclk-external-frequency:
      if mclk-external-frequency < sample-rate * bits-per-sample * 2:
        throw "INVALID_ARGUMENT"
    else:
      mclk-external-frequency = -1

    i2s-configure_
        i2s_
        sample-rate
        bits-per-sample
        mclk-multiplier
        mclk-external-frequency
        format
        slots-in
        slots-out
        tx-pin
        rx-pin
        mclk-pin
        sck-pin
        ws-pin

  /**
  Variant of $(configure --slots-in --slots-out --sample-rate --bits-per-sample) that
    sets both slots to the same value.
  */
  configure
      --mclk-external-frequency/int?=null
      --mclk-multiplier/int?=null
      --sample-rate/int
      --bits-per-sample/int
      --format/int=FORMAT-PHILIPS
      --slots/int=SLOTS-STEREO-BOTH:
    configure
      --mclk-external-frequency=mclk-external-frequency
      --mclk-multiplier=mclk-multiplier
      --sample-rate=sample-rate
      --bits-per-sample=bits-per-sample
      --format=format
      --slots-in=slots
      --slots-out=slots

  /**
  Deprecated.
    $is-master has been renamed to '--master' and is now mandatory.
    $use-apll is no longer supported.
    $buffer-size is no longer supported.
    The bus must be constructed, configured, and started manually.
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
    bus := Bus
        --master=is-master
        --sck=sck
        --ws=ws
        --tx=tx
        --rx=rx
        --mclk=mclk
    needs-close := true
    try:
      bus.configure
          --sample-rate=sample-rate
          --bits-per-sample=bits-per-sample
          --mclk-multiplier=mclk-multiplier
          --slots=SLOTS-STEREO-BOTH
      bus.start
      needs-close = false
      return bus
    finally:
      if needs-close: bus.close

  /**
  Number of encountered errors.

  If $overrun is true and includes overrun errors.
  If $underrun is true includes underrun errors.
  If $overrun and $underrun are null (the default), then both types of errors
    are included.
  If $overrun (resp. $underrun) is not null, and $underrun (resp. $overrun) is
    null, then the null-parameter is treated as false.

  Overrun errors happen when the program is not fast enough to read
    the buffers.
  Underrun errors happen when the program is not fast enough to write
    the buffers.
  */
  errors --overrun/bool?=null --underrun/bool?=null -> int:
    result := 0
    if overrun == null and underrun == null:
      overrun = true
      underrun = true
    if overrun: result += i2s_errors-overrun_ i2s_
    if underrun: result += i2s_errors-underrun_ i2s_
    return result

  /**
  Starts the bus.

  Usually the bus is started automatically when it is created. However, if
    the bus was created with the $start flag set to false, then this method
    must be called to start the bus.

  When a bus was constructed but not started yet, then the master clock is
    running, but the other signals are not. Specifically, in master mode,
    there is no clock, word-select or data being transmitted.

  The bus must not already be started.

  There is no need to $stop a bus. Calling $close is enough.
  */
  start -> none:
    if not i2s_: throw "CLOSED"
    i2s-start_ i2s_

  /**
  Stops the bus.

  It's rare that you need to stop the bus. Usually, you just close it.
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

  # Esp32
  On the ESP32 (but not its variants), the buffer needs to be padded for
    8 and 24 bits samples. That is, for 8 bits, samples should be provided
    in 16-bit blocks and only the highest 8 bits are used. For 24 bits,
    each sample should be 32 bits, where only the highest 24 bits are used.
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

  See $write for ESP32-specific notes.
  */
  try-write bytes/ByteArray -> int:
    while true:
      if not i2s_: throw "CLOSED"

      state_.clear-state WRITE-STATE_ | ERROR-STATE_

      written := i2s-write_ i2s_ bytes
      if written != 0: return written
      // Try again without waiting for signals.
      written = i2s-write_ i2s_ bytes
      if written != 0: return written

      state := state_.wait-for-state WRITE-STATE_ | ERROR-STATE_

  /**
  Reads bytes from the I2S bus.

  This methods blocks until data is available.

  # Esp32
  On the ESP32 (but not its variants), the buffer is padded for
    8 and 24 bits samples. That is, for 8 bits, samples are provided
    in 16-bit blocks and only the highest 8 bits are used. For 24 bits,
    each sample is given as 32 bits, where only the highest 24 bits are
    used.
  */
  read -> ByteArray?:
    result := ByteArray 496
    count := read result
    if count < 350:
      // Avoid wasting too much memory.
      return result[..count].copy
    return result[..count]

  /**
  Reads bytes from the I2S bus to a buffer.

  This methods blocks until data is available.

  See $read for ESP32-specific notes.
  */
  read buffer/ByteArray -> int?:
    while true:
      if not i2s_: throw "CLOSED"

      state_.clear-state READ-STATE_ | ERROR-STATE_

      read := i2s-read-to-buffer_ i2s_ buffer
      if read > 0: return read
      state := state_.wait-for-state READ-STATE_ | ERROR-STATE_
      state_.clear-state READ-STATE_ | ERROR-STATE_

  /**
  Closes the I2S bus and releases resources associated to it.
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
    tx-pin
    rx-pin
    is-master:
  #primitive.i2s.create

i2s-configure_
    i2s_
    sample-rate
    bits-per-sample
    mclk-multiplier
    mclk-external-frequency
    format
    slots-in
    slots-out
    tx-pin
    rx-pin
    mclk-pin
    sck-pin
    ws-pin:
  #primitive.i2s.configure

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

i2s-errors-underrun_ i2s -> int:
  #primitive.i2s.errors-underrun

i2s-errors-overrun_ i2s -> int:
  #primitive.i2s.errors-overrun
