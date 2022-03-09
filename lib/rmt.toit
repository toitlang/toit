// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio

/**
Support for the ESP32 Remote Control (RMT).

The $Channel represents a channel in the controller.

An $Item represents an item from the controller.
*/

/**
An Item to be transferred or received with RMT.

An RMT item consists of a level (low or high) and a period (the amount of
  ticks the level is sustained).

# Advanced
The period is specified in number of ticks, so the actual time the level is
  sustained is determined by the RMT controller configuration.

At the lower level, an item consits of 16 bits: 15 bits for the period and 1
  bit for the level.
*/
class Items:
  size/int
  bytes/ByteArray

  constructor .size:
    bytes = construct_bytes_ size

  static construct_bytes_ size/int -> ByteArray:
    should_pad := size % 2 == 1
    bytes_size := should_pad ? size * 2 + 2 : size * 2
    return ByteArray bytes_size

  // TODO what's a nice convenient constructor for populating Items with known values?

  constructor.from_bytes .bytes/ByteArray:
    if bytes.size % 4 != 0: throw "INVALID_ARGUMENT"

    size = bytes.size / 2

  item_level i/int -> int:
    check_bounds_ i
    return item_level_ i

  item_period i/int -> int:
    check_bounds_ i
    return item_period_ i

  set_item i/int period/int level/int -> none:
    check_bounds_ i
    idx := i * 2
    period = period & 0x7FFF
    level = level & 0b1
    bytes[idx] = period & 0xFF
    bytes[idx + 1] = (period >> 8 ) | (level << 7)

  do [block]:
    size.repeat:
      block.call
        item_period_ it
        item_level_ it

  check_bounds_ i:
    if not 0 <= i < size: throw "OUT_OF_BOUNDS"

  item_level_ i -> int:
    return bytes[i * 2 + 1] >> 7

  item_period_ i -> int:
    idx := i * 2
    return bytes[idx] | ((bytes[idx + 1] & 0x7F) << 8)

/**
An RMT channel.

The channel must be configured after construction.

The channel can be configured for either RX or TX.
*/
class Channel:
  num/int
  pin/gpio.Pin

  res_/ByteArray? := null

  /** Constructs a channel using the given $num using the given $pin. */
  constructor .pin .num:
    res_ = rmt_use_ resource_group_ num

  /**
  Configure the channel for RX.

  - $mem_block_num is the number of memory blocks (512 bytes) used by this channel.
  - $clk_div is the source clock divider. Must be in the range [0,255].
  - $flags is the configuration flags. See the ESP-IDF documentation for available flags.
  - $idle_threshold is the amount of clock cycles the receiver will run without seeing an edge.
  - $filter_en is whether the filter is enabled.
  - $filter_ticks_thresh pulses shorter than this value is filtered away.
    Only works with $filter_en. The value must be in the range [0,255].
  */
  config_rx
      --mem_block_num/int=1
      --clk_div/int=80
      --flags/int=0
      --idle_threshold/int=12000
      --filter_en/bool=true
      --filter_ticks_thresh/int=100
      --rx_buffer_size=128:
    rmt_config_rx_ pin.num num mem_block_num clk_div flags idle_threshold filter_en filter_ticks_thresh rx_buffer_size

  /**
  Configure the channel for TX.

  - $mem_block_num is the number of memory blocks (512 bytes) used by this channel.
  - $clk_div is the source clock divider. Must be in the range [0,255].
  - $flags is the configuration flags. See the ESP-IDF documentation for available flags.
  - $carrier_en is whether a carrier wave is used.
  - $carrier_freq_hz is the frequency of the carrier wave.
  - $carrier_level is the way the carrier way is modulated.
    Set to 1 to transmit on low output level and 0 to transmit on high output level.
  - $carrier_duty_percent is the proportion of time the carrier wave is low.
  - $loop_en is whether the transmitter continously writes the provided items in a loop.
  - $idle_output_en is whether the transmitter outputs when idle.
  - $idle_level is the level transmitted by the transmitter when idle.
  */
  config_tx
      --mem_block_num/int=1
      --clk_div/int=80
      --flags/int=0
      --carrier_en/bool=false
      --carrier_freq_hz/int=38000
      --carrier_level/int=1
      --carrier_duty_percent/int=33
      --loop_en/bool=false
      --idle_output_en/bool=true
      --idle_level/int=0:
    rmt_config_tx_ pin.num num mem_block_num clk_div flags carrier_en carrier_freq_hz carrier_level carrier_duty_percent loop_en idle_output_en idle_level

  close:
    if res_:
      rmt_unuse_ resource_group_ res_
      res_ = null

transfer channel/Channel items/Items:
  rmt_transfer_ channel.num items.bytes

transfer_and_read --rx/Channel --tx/Channel items/Items max_items_size/int -> Items:
  result := rmt_transfer_and_read_ tx.num rx.num items.bytes max_items_size
  return Items.from_bytes result

resource_group_ ::= rmt_init_

rmt_init_:
  #primitive.rmt.init

rmt_use_ resource_group channel_num:
  #primitive.rmt.use

rmt_unuse_ resource_group resource:
  #primitive.rmt.unuse

rmt_config_rx_ pin_num/int channel_num/int mem_block_num/int clk_div/int flags/int
    idle_threshold/int filter_en/bool filter_ticks_thresh/int rx_buffer_size/int:
  #primitive.rmt.config_rx

rmt_config_tx_ pin_num/int channel_num/int mem_block_num/int clk_div/int flags/int
    carrier_en/bool carrier_freq_hz/int carrier_level/int carrier_duty_percent/int
    loop_en/bool idle_output_en/bool idle_level/int:
  #primitive.rmt.config_tx

rmt_transfer_ tx_ch/int items_bytes/*/Blob*/:
  #primitive.rmt.transfer

rmt_transfer_and_read_ tx_ch/int rx_ch/int items_bytes/*/Blob*/ max_output_len/int:
  #primitive.rmt.transfer_and_read
