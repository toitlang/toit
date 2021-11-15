// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio

import serial

/**
I2S Serial communication Bus, primarily used to emit sound but has a wide range of usages.

The I2S Bus works closely with the underlying hardware units, which means that some restrictions
  around buffer and write sizes are enforced.
*/
class Bus:
  i2s_ := ?

  /**
  Initializes the I2S bus.

  $sample_rate is the rate at which samples are written.
  $bits_per_sample is the width of each sample. It can be either 16, 24 or 32.
  $buffer_size, in bytes, is used as size for internal buffers.
    All writes must be aligned to this size.
    The $buffer_size must be aligned with $bits_per_sample (in bytes) * 2.
  */
  constructor
      --sck/gpio.Pin?=null
      --ws/gpio.Pin?=null
      --tx/gpio.Pin?=null
      --sample_rate/int
      --bits_per_sample/int
      --buffer_size/int=(32 * 2 * bits_per_sample / 8):
    if buffer_size % (2 * bits_per_sample / 8) != 0: throw "INVALID_ARGUMENT"
    sck_pin := sck ? sck.num : -1
    ws_pin := ws ? ws.num : -1
    tx_pin := tx ? tx.num : -1
    i2s_ = i2s_init_ sck_pin ws_pin tx_pin sample_rate bits_per_sample buffer_size

  /**
  Writes the bytes to the I2S bus.

  This methods blocks until the internal buffer has accepted all of the data.

  It's an error if the bytes of the bytes are not aligned to the bus' buffer_size.
  */
  write bytes/ByteArray -> int:
    return i2s_write_ i2s_ bytes

  /**
  Close the I2S bus and releases resources associated to it.
  */
  close:
    if i2s_:
      i2s_close_ i2s_
      i2s_ = null

i2s_init_ data_pin clock_pin channel_pin sample_rate bits_per_sample buffer_size:
  #primitive.i2s.init

i2s_close_ i2s:
  #primitive.i2s.close

i2s_write_ i2s bytes -> int:
  #primitive.i2s.write
