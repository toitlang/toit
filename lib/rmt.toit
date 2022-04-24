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

/** Bytes per ESP32 signal. */
BYTES_PER_SIGNAL ::= 2

/**
A collection of signals to be transmitted or received with the RMT controller.

An RMT signal consists of a level (low or high) and a period (the number of
  ticks the level is sustained).

# Advanced
The period is specified in number of ticks, so the actual time the level is
  sustained is determined by the RMT controller configuration.

At the lower level, a signal consists of 16 bits: 15 bits for the period and 1
  bit for the level. Signals must be transmitted as pairs also known as an item.
  For this reason, the bytes backing a collection of signal is always adjusted
  to be divisible by 4.
*/
class Signals:
  /** The number of signals in the collection. */
  size/int

  bytes_/ByteArray

  /** The empty signal collection. */
  static ZERO ::= Signals 0

  /**
  Creates a collection of signals of the given $size.

  All signals are initialized to 0 period and 0 level.

  # Advanced
  If the given $size is not divisible by 2, then the byte array allocated for
    $bytes_ is padded with two bytes to make the $bytes_ usable by the RMT
    primitives. The final signal is initialized to 0 period and level 1.
  */
  constructor .size:
    bytes_ = ByteArray
        round_up (size * 2) 4
    if size % 2 == 1: set_signal_ size 0 1

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
  constructor.alternating size/int --first_level/int [block]:
    if first_level != 0 and first_level != 1: throw "INVALID_ARGUMENT"

    signals := Signals size
    level := first_level
    size.repeat:
      signals.set it --period=(block.call it level) --level=level
      level ^= 1

    return signals


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
  Returns the signal period of the $i'th signal.

  The given $i must be in the range [0..$size[.
  */
  period i/int -> int:
    check_bounds_ i
    return signal_period_ i

  /**
  Returns the signal level of the $i'th signal.

  The given $i must be in the range [0..$size[.
  */
  level i/int -> int:
    check_bounds_ i
    return signal_level_ i

  /**
  Sets the $i'th signal to the given $period and $level.

  The given $i must be in the range [0..$size[.

  The given $period must be in the range [0..0x7FFF].

  The given $level must be 0 or 1.
  */
  set i/int --period/int --level/int -> none:
    check_bounds_ i
    set_signal_ i period level

  set_signal_ i/int period/int level/int -> none:
    idx := i * 2
    if not 0 <= period <= 0x7FFF or level != 0 and level != 1: throw "INVALID_ARGUMENT"

    bytes_[idx] = period & 0xFF
    bytes_[idx + 1] = (period >> 8 ) | (level << 7)

  /**
  Invokes the given $block on each signal of this signal collection.

  The block is invoked with the level and period of each signal.
  */
  do [block]:
    size.repeat:
      block.call
        signal_level_ it
        signal_period_ it

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

  idle_threshold_/int? := null
  rx_buffer_size_/int? := null
  rx_clk_div_/int?     := null
  /**
  Constructs a channel using the given $num using the given $pin.

  The given $num must be in the range [0,7] and must not be in use.
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

  The $clk_div divides the APB (advanced peripheral bus) clock. The APB clock is set to 80MHz.
  The $filter_ticks_thresh counts APB bus ticks. As such, a value of 80 is equivalent to 1us.
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
    idle_threshold_ = idle_threshold
    rx_buffer_size_ = rx_buffer_size
    rx_clk_div_ = clk_div

  idle_threshold -> int?:
    return idle_threshold_

  idle_threshold= threshold/int -> none:
    rmt_set_idle_threshold_ num threshold

  rx_buffer_size -> int?:
    return rx_buffer_size_

  rx_clk_div -> int?:
    return rx_clk_div_

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
  - $loop_en is whether the transmitter continuously writes the provided signals in a loop.
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

  /**
  Configures the underlying pin for reception and transmission.

  Must be called on the tx channel.

  # Usage
  In order to configure a pin for reception and transmission, the following
    configuration steps must happen (in the given order):
  - Configure tx channel with $config_tx.
  - Configure rx channel with $config_rx.
  - Configure reception/transmission with $config_bidirectional_pin (must be
    called on the tx channel).

  # Advanced
  Configuring a pin for reception and transmission allows the implementation
    of protocols such as 1-wire.
  */
  config_bidirectional_pin:
    rmt_config_bidirectional_pin_ pin.num num

  /** Closes the channel. */
  close:
    if res_:
      rmt_unuse_ resource_group_ res_
      res_ = null

/**
Transmits the given $signals over the given $channel.

The $channel must be configured for transmitting (see $Channel.config_tx).
*/
transmit channel/Channel signals/Signals -> none:
  rmt_transmit_ channel.num signals.bytes_

/**
Transmits the given signals while simultaneously receiving.

The transmits the given $transmit signals followed by the given $receive
  signals. The signals are transmitted over the given $tx channel and signals
  are received on the $rx channel.

The RMT controller starts receiving signals after the given $transmit signals
  have been transmitted.

The given $max_returned_bytes specifies the maximum byte size of the returned
  signals. The $max_returned_bytes must be smaller than the configured RX
  buffer size for the $rx channel.

If $max_returned_bytes is not sufficient to store all received signals, then the
  result is truncated. If it is important to detect this condition, then the user should
  set $max_returned_bytes to a value greater than the maximum expected signal byte size.

The $rx channel must be configured for receiving (see $Channel.config_rx).

The $tx channel must be configured for transmitting (see $Channel.config_tx).
*/
transmit_and_receive --rx/Channel --tx/Channel --transmit/Signals=Signals.ZERO --receive/Signals=Signals.ZERO max_returned_bytes/int -> Signals:
  if not rx.rx_buffer_size and rx.rx_clk_div: throw "rx channel not configured"

  if max_returned_bytes > rx.rx_buffer_size: throw "maximum returned buffer size greater than allocated RX buffer size"

  receive_timeout := rx.idle_threshold * rx.rx_clk_div
  result := rmt_transmit_and_receive_ tx.num rx.num transmit.bytes_ receive.bytes_ max_returned_bytes receive_timeout
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

rmt_set_idle_threshold_ channel_num/int threshold/int:
  #primitive.rmt.set_idle_threshold

rmt_config_tx_ pin_num/int channel_num/int mem_block_num/int clk_div/int flags/int
    carrier_en/bool carrier_freq_hz/int carrier_level/int carrier_duty_percent/int
    loop_en/bool idle_output_en/bool idle_level/int:
  #primitive.rmt.config_tx

rmt_config_bidirectional_pin_ pin/int tx/int:
  #primitive.rmt.config_bidirectional_pin

rmt_transmit_ tx_ch/int signals_bytes/*/Blob*/:
  #primitive.rmt.transmit

rmt_transmit_and_receive_ tx_ch/int rx_ch/int transmit_bytes/*/Blob*/ receive_bytes max_output_len/int receive_timeout/int:
  #primitive.rmt.transmit_and_receive
