// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import monitor show ResourceState_

import serial

/**
I2S Serial communication Bus, primarily used to emit sound but has a wide range of usages.

The I2S Bus works closely with the underlying hardware units, which means that
  some restrictions around buffer and write sizes are enforced.
*/
class Bus:
  i2s_ := ?
  state_/ResourceState_ ::= ?
  /** Number of encountered errors. */
  errors := 0

  /**
  Initializes the I2S bus.

  $sample-rate is the rate at which samples are written.
  $bits-per-sample is the width of each sample. It can be either 16, 24 or 32.
  $buffer-size, in bytes, is used as size for internal buffers.
  $mclk is the pin used to output the master clock. Only relevant when the I2S
    Bus is operating in master mode.
  $mclk-multiplier is the muliplier of the $sample-rate to be used for the
    master clock.
    It should be one of the 128, 256 or 384.
    It is only relevant if the $mclk is not null.
  $is-master is a flag determining if the I2S driver should run in master
    (true) or slave (false) mode.
  $use-apll use a high precision clock.
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
      --buffer-size/int=(32 * 2 * bits-per-sample / 8):
    sck-pin := sck ? sck.num : -1
    ws-pin := ws ? ws.num : -1
    tx-pin := tx ? tx.num : -1
    rx-pin := rx ? rx.num : -1
    mclk-pin := mclk ? mclk.num : -1
    i2s_ = i2s-create_ resource-group_ sck-pin ws-pin tx-pin rx-pin mclk-pin sample-rate bits-per-sample buffer-size is-master mclk-multiplier use-apll
    state_ = ResourceState_ resource-group_ i2s_


  /**
  Writes bytes to the I2S bus.

  This method blocks until some data has been written.

  Returns the number of bytes written.
  */
  write bytes/ByteArray -> int:
    while true:
      written := i2s-write_ i2s_ bytes
      if written != 0: return written

      state_.clear-state WRITE-STATE_
      state := state_.wait-for-state WRITE-STATE_ | ERROR-STATE_

      if not i2s_: throw "CLOSED"

      if state & ERROR-STATE_ != 0:
        state_.clear-state ERROR-STATE_
        errors++

  /**
  Read bytes from the I2S bus.

  This methods blocks until data is available.
  */
  read -> ByteArray?:
    while true:
      state := state_.wait-for-state READ-STATE_ | ERROR-STATE_
      if state & ERROR-STATE_ != 0:
        state_.clear-state ERROR-STATE_
        errors++
      else if state & READ-STATE_ != 0:
        data := i2s-read_ i2s_
        if data.size > 0: return data
        state_.clear-state READ-STATE_
      else:
        // It was closed (disposed).
        return null

  /**
  Read bytes from the I2S bus to a buffer.

  This methods blocks until data is available.
  */
  read buffer/ByteArray -> int?:
    while true:
      state := state_.wait-for-state READ-STATE_ | ERROR-STATE_
      if state & ERROR-STATE_ != 0:
        state_.clear-state ERROR-STATE_
        errors++
      else if state & READ-STATE_ != 0:
        read := i2s-read-to-buffer_ i2s_ buffer
        if read > 0: return read
        state_.clear-state READ-STATE_
      else:
        // It was closed (disposed).
        return null

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

i2s-create_ resource-group sck-pin ws-pin tx-pin rx-pin mclk-pin sample-rate bits-per-sample buffer-size is-master mclk-multiplier use-apll:
  #primitive.i2s.create

i2s-close_ resource-group i2s:
  #primitive.i2s.close

i2s-write_ i2s bytes -> int:
  #primitive.i2s.write

i2s-read_ i2s -> ByteArray:
  #primitive.i2s.read

i2s-read-to-buffer_ i2s buffer:
  #primitive.i2s.read-to-buffer
