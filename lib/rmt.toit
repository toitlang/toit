// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import binary show LITTLE_ENDIAN

/**
Support for the ESP32 Remote Control (RMT).

A $Channel corresponds to a channel in the ESP32 RMT controller.

$Signals represent a collection of signals to be sent by the RMT controller.
*/

/**
A collection of signals to be transferred or received with the RMT controller.

An RMT signal consists of a level (low or high) and a period (the number of
  ticks the level is sustained).

# Advanced
The period is specified in number of ticks, so the actual time the level is
  sustained is determined by the RMT controller configuration.

At the lower level, a signal consits of 16 bits: 15 bits for the period and 1
  bit for the level. Signals must be transfered as pairs also known as an item.
*/
class Signals:
  /** The number of signals in the collection. */
  size/int

  bytes_/ByteArray

  /**
  Creates a collection of signals of the given $size.

  All signals are initialized to 0 period and 0 level.
  
  # Advanced
  If the given $size is not divisible by 2, then the byte array allocted for 
    $bytes_ is patted with two bytes to make the $bytes_ usable by the RMT 
    primitives.
  */
  constructor .size:
    bytes_ = ByteArray
        round_up (size * 2) 4

  /**
  Creates signals that alternate between a level of 0 and 1 with the periods 
    given in the indexable collection $periods. 

  The level of the first signal is $first_level.
  */
  constructor.alternating --first_level/int periods: 
    if first_level != 0 and first_level != 1: throw "INVALID_ARGUMENT"

    return Signals.alternating periods.size --first_level=first_level: | idx |
      periods[idx]

  /**
  Creates items that alternate between a level of 0 and 1 with the periods 
    given by successive calls to the block. 

  The $block is called with the signal index and the level it is created with.

  The level of the first signal is $first_level.
  */ 
  constructor.alternating size/int --first_level [block]:
    if first_level != 0 and first_level != 1: throw "INVALID_ARGUMENT"

    signals := Signals size
    level := first_level
    size.repeat:
      signals.set_signal it level (block.call it level)
      level = level ^ 1

    return signals


  // TODO what's a nice convenient constructor for populating Signals with known values?

  /**
  Creates a collection of signals from the given $bytes.

  The $bytes size must be divisible by 4.

  # Advanced
  The bytes must correspond to bytes produced by the RMT primitives. The 
    primitives operate with pairs of signals (called an item) which  is the 
    reason the $bytes size must be divisible by 4.
  */
  constructor.from_bytes bytes/ByteArray:
    if bytes.size % 4 != 0: throw "INVALID_ARGUMENT"

    bytes_ = bytes
    size = bytes_.size / 2

  /** 
  Gets the signal period of the $i'th signal. 
  
  The given $i must be in the range [0,$size[.
  */
  signal_period i/int -> int:
    check_bounds_ i
    return signal_period_ i

  /** 
  Gets the signal level of the $i'th signal. 
  
  The given $i must be in the range [0,$size[.
  */
  signal_level i/int -> int:
    check_bounds_ i
    return signal_level_ i

  /**
  Set the $i'th signal to the given $period and $level.

  The given $i must be in the range [0,$size[.
  
  The given $period must be in the range [0,0x7FFF].

  The given $level must be 0 or 1.
  */
  set_signal i/int period/int level/int -> none:
    check_bounds_ i
    idx := i * 2
    if not 0 <= period <= 0x7FFF or level != 0 and level != 1: throw "INVALID_ARGUMENT"

    bytes_[idx] = period & 0xFF
    bytes_[idx + 1] = (period >> 8 ) | (level << 7)

  /** 
  Invokes the given $block on each signal of this signal collection. 
  
  The block is invoked with the period and the level of each signal.
  */
  do [block]:
    size.repeat:
      block.call
        signal_period_ it
        signal_level_ it

  check_bounds_ i:
    if not 0 <= i < size: throw "OUT_OF_BOUNDS"

  signal_level_ i -> int:
    return bytes_[i * 2 + 1] >> 7

  signal_period_ i -> int:
    idx := i * 2
    return (LITTLE_ENDIAN.uint16 bytes_ idx) & 0x7fff

/**
An RMT channel.

The channel must be configured after construction.

The channel can be configured for either RX or TX.
*/
class Channel:
  num/int
  pin/gpio.Pin

  res_/ByteArray? := null

  /** 
  Constructs a channel using the given $num using the given $pin. 
  
  The givn $num must be in the range [0,7] and must not be in use.
  */
  constructor .pin .num:
    res_ = rmt_use_ resource_group_ num

  /**
  Configure the channel for RX.

  - $mem_block_num is the number of memory blocks (256 bytes or 128 signals) 
    used by this channel.
  - $clk_div is the source clock divider. Must be in the range [0,255].
  - $flags is the configuration flags. See the ESP-IDF documentation for available flags.
  - $idle_threshold is the number of clock cycles the receiver will run without seeing an edge.
  - $filter_en is whether the filter is enabled.
  - $filter_ticks_thresh pulses shorter than this value is filtered away.
    Only works with $filter_en. The value must be in the range [0,255].
  
  # Advanced
  If $mem_block_num is greater than 1, then it will take the memory of the 
    subsequent channels. For instance, if channel 2 is configured with a
    $mem_block_num = 3, then channels 3 and 4 are unusable.
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

  - $mem_block_num is the number of memory blocks (256 bytes or 128 signals) 
    used by this channel.
  - $clk_div is the source clock divider. Must be in the range [0,255].
  - $flags is the configuration flags. See the ESP-IDF documentation for available flags.
  - $carrier_en is whether a carrier wave is used.
  - $carrier_freq_hz is the frequency of the carrier wave.
  - $carrier_level is the way the carrier way is modulated.
    Set to 1 to transmit on low output level and 0 to transmit on high output level.
  - $carrier_duty_percent is the proportion of time the carrier wave is low.
  - $loop_en is whether the transmitter continously writes the provided signals in a loop.
  - $idle_output_en is whether the transmitter outputs when idle.
  - $idle_level is the level transmitted by the transmitter when idle.

  # Advanced
  If $mem_block_num is greater than 1, then it will take the memory of the 
    subsequent channels. For instance, if channel 2 is configured with a
    $mem_block_num = 3, then channels 3 and 4 are unusable.
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

/** Transfers the given $signals over the given $channel.*/
transfer channel/Channel signals/Signals -> none:
  rmt_transfer_ channel.num signals.bytes_

/**
Transfers the given $signals while simoultaniously receiving.

The $signals are transferred over the given $tx channel and signals are received on the $rx channel.

The given $max_items_size specifies the maximum byte size of the returned signals.
*/
transfer_and_receive --rx/Channel --tx/Channel signals/Signals max_items_size/int -> Signals:
  result := rmt_transfer_and_read_ tx.num rx.num signals.bytes_ max_items_size
  return Signals.from_bytes result

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

rmt_transfer_ tx_ch/int signals_bytes/*/Blob*/:
  #primitive.rmt.transfer

rmt_transfer_and_read_ tx_ch/int rx_ch/int signals_bytes/*/Blob*/ max_output_len/int:
  #primitive.rmt.transfer_and_read
