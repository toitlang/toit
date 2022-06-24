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

  $sample_rate is the rate at which samples are written.
  $bits_per_sample is the width of each sample. It can be either 16, 24 or 32.
  $buffer_size, in bytes, is used as size for internal buffers.
    All writes must be aligned to this size.
    The $buffer_size must be aligned with $bits_per_sample (in bytes) * 2.
  $mclk is the pin used to output the master clock. Only relevant when the I2S
    Bus is operating in master mode.
  $mclk_multiplier is the muliplier of the $sample_rate to be used for the
    master clock.
    It should be one of the 128, 256 or 384.
    It is only relevant if the $mclk is not null.
  $is_master is a flag determining if the I2S driver should run in master
    (true) or slave (false) mode.
  $use_apll use a high precision clock.
  */
  constructor
      --sck/gpio.Pin?=null
      --ws/gpio.Pin?=null
      --tx/gpio.Pin?=null
      --rx/gpio.Pin?=null
      --mclk/gpio.Pin?=null
      --sample_rate/int
      --bits_per_sample/int
      --is_master/bool=true
      --mclk_multiplier/int=256
      --use_apll/bool=false
      --buffer_size/int=(32 * 2 * bits_per_sample / 8):
    if buffer_size % (2 * bits_per_sample / 8) != 0: throw "INVALID_ARGUMENT"
    if mclk and mclk.num != 0 and mclk.num != 1 and mclk.num != 3: throw "INVALID_ARGUMENT"
    sck_pin := sck ? sck.num : -1
    ws_pin := ws ? ws.num : -1
    tx_pin := tx ? tx.num : -1
    rx_pin := rx ? rx.num : -1
    mclk_pin := mclk ? mclk.num : -1
    i2s_ = i2s_create_ resource_group_ sck_pin ws_pin tx_pin rx_pin mclk_pin sample_rate bits_per_sample buffer_size is_master mclk_multiplier use_apll
    state_ = ResourceState_ resource_group_ i2s_


  /**
  Writes the bytes to the I2S bus.

  This methods blocks until the internal buffer has accepted all of the data or
    the underlying resource was closed.

  Returns the number of bytes written or -1 if the underlying resource was
    closed.

  It's an error if the bytes of the bytes are not aligned to the bus'
    buffer_size.
  */
  write bytes/ByteArray -> int:
    written/int := 0
    while written < bytes.size:
      written_next := i2s_write_ i2s_ bytes[written..]
      written += written_next
      if written_next == 0:
        state_.clear_state WRITE_STATE_
        state := state_.wait_for_state WRITE_STATE_ | ERROR_STATE_
        if state & ERROR_STATE_ != 0:
          state_.clear_state ERROR_STATE_
          errors++
        else if state & WRITE_STATE_ != 0:
          // This is expected, and the loop continues.
        else:
          // It was closed (disposed).
          return -1
    return written

  /**
  Read bytes from the I2S bus.

  This methods blocks until data is available.
  */
  read -> ByteArray?:
    while true:
      state := state_.wait_for_state READ_STATE_ | ERROR_STATE_
      if state & ERROR_STATE_ != 0:
        state_.clear_state ERROR_STATE_
        errors++
      else if state & READ_STATE_ != 0:
        data := i2s_read_ i2s_
        if data.size > 0: return data
        state_.clear_state READ_STATE_
      else:
        // It was closed (disposed).
        return null

  /**
  Read bytes from the I2S bus to a buffer.

  This methods blocks until data is available.
  */
  read buffer/ByteArray -> int?:
    while true:
      state := state_.wait_for_state READ_STATE_ | ERROR_STATE_
      if state & ERROR_STATE_ != 0:
        state_.clear_state ERROR_STATE_
        errors++
      else if state & READ_STATE_ != 0:
        read := i2s_read_to_buffer_ i2s_ buffer
        if read > 0: return read
        state_.clear_state READ_STATE_
      else:
        // It was closed (disposed).
        return null

  /**
  Close the I2S bus and releases resources associated to it.
  */
  close:
    if not i2s_: return
    critical_do:
      state_.dispose
      i2s_close_ resource_group_ i2s_
      i2s_ = null

resource_group_ ::= i2s_init_

READ_STATE_  ::= 1 << 0
WRITE_STATE_ ::= 1 << 1
ERROR_STATE_ ::= 1 << 2


i2s_init_:
  #primitive.i2s.init

i2s_create_ resource_group sck_pin ws_pin tx_pin rx_pin mclk_pin sample_rate bits_per_sample buffer_size is_master mclk_multiplier use_apll:
  #primitive.i2s.create

i2s_close_ resource_group i2s:
  #primitive.i2s.close

i2s_write_ i2s bytes -> int:
  #primitive.i2s.write

i2s_read_ i2s -> ByteArray:
  #primitive.i2s.read

i2s_read_to_buffer_ i2s buffer:
  #primitive.i2s.read_to_buffer
