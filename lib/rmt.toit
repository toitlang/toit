// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import binary show LITTLE_ENDIAN

/**
Support for the ESP32 Remote Control (RMT).

A $Channel corresponds to a channel in the ESP32 RMT controller.

$Signals represent a collection of signals to be sent by the RMT controller.

# WARNING
This implementation is incomplete and may block while receiving data from the RMT unit.
  Contrary to other blocking Toit calls, this call prevents other tasks to run. Even worse,
  it prevents the garbage collector to run while waiting. This can lead to a full
  freeze of the Toit system until the receiving function returns.
*/

/**
A collection of signals to be written or read with the RMT controller.

An RMT signal consists of a level (low or high) and a period (the number of
  ticks the level is sustained).

# Advanced
The period is specified in number of ticks, so the actual time the level is
  sustained is determined by the RMT controller configuration.

At the lower level, a signal consists of 16 bits: 15 bits for the period and 1
  bit for the level. Signals must be written as pairs also known as an item.
  For this reason, the bytes backing a collection of signal is always adjusted
  to be divisible by 4.

This class fills in the unused bytes with values that have no effect on the output.
  Due to https://github.com/espressif/esp-idf/issues/8864 it always allocates an
  additional signal so it can add an end marker.
*/
class Signals:
  /** Bytes per ESP32 signal. */
  static BYTES_PER_SIGNAL ::= 2

  /** The number of signals in the collection. */
  size/int

  bytes_/ByteArray

  /** The empty signal collection. */
  static ZERO ::= Signals 0

  /**
  Creates a collection of signals of the given $size.

  All signals are initialized to 0 period and 0 level.

  # Advanced
  The underlying RMT peripheral can only work on byte arrays that are divisible by
    4 (equivalent to 2 signals).

  This constructor always adds an end-marker signal.

  In consequence, the size of the backing byte array might be 4 bytes larger than
    $size * $BYTES_PER_SIGNAL.
  */
  // TODO(florian): take a clock-divider as argument and allow the user to specify
  // durations in us. Then also add a `do --us_periods:`.
  constructor .size:
    size_with_end_marker := size + 1
    bytes_ = ByteArray
        round_up (size_with_end_marker * 2) 4
    // Work around https://github.com/espressif/esp-idf/issues/8864 and always add a
    // high end marker.
    set_signal_ size 0 1
    if size_with_end_marker % 2 == 1: set_signal_ (size + 1) 0 1

  /**
  Creates signals that alternate between a level of 0 and 1 with the periods
    given in the $periods list.

  The level of the first signal is $first_level.
  */
  constructor.alternating --first_level/int periods/List:
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
  static DEFAULT_CLK_DIV ::= 80
  static DEFAULT_IN_CLK_DIV ::= DEFAULT_CLK_DIV
  static DEFAULT_IN_IDLE_THRESHOLD ::= 12000
  static DEFAULT_IN_ENABLE_FILTER ::= true
  static DEFAULT_IN_FILTER_TICKS_THRESHOLD ::= 100
  static DEFAULT_IN_FLAGS ::= 0
  static DEFAULT_IN_BUFFER_SIZE ::= 128
  static DEFAULT_OUT_CLK_DIV ::= DEFAULT_CLK_DIV
  static DEFAULT_OUT_FLAGS ::= 0
  static DEFAULT_OUT_ENABLE_CARRIER ::= false
  static DEFAULT_OUT_CARRIER_FREQUENCY ::= 38000
  static DEFAULT_OUT_CARRIER_LEVEL ::= 1
  static DEFAULT_OUT_CARRIER_DUTY_PERCENT ::= 33
  static DEFAULT_OUT_IDLE_LEVEL ::= null
  static DEFAULT_READ_TIMEOUT_MS ::= 100

  pin       /gpio.Pin
  resource_ /ByteArray? := ?

  rx_buffer_size_/int? := null

  // 0 = not configured, 1 = configured for input, 2 = configured for output
  configured_ /int := 0

  /**
  Constructs a channel using the given $num using the given $pin.

  The $memory_block_count determines how many memory blocks are assigned to this channel. See
    the Advanced section for more information.

  The $channel_id should generally be left as default. If provided, it selects the
    channel with that physical id. On a standard ESP32, there are 8 channels which can be
    selected by providing a channel id in the range [0,7]. See the advanced section for
    when this can be useful.

  This constructor does not configure the channel for input or output yet. Call $configure
    (either `--input` or `--output`) to do so.

  # Advanced

  The $memory_block_count determines how many memory blocks are assigned to this channel.
    Memory blocks are of size 256 bytes or 128 signals. They are in continuous memory and
    there are only a limited number of them.

  If a channel requests more than one memory block, then the following internal channel id is
    marked as used as well.

  Users might run into fragmentation issues as well: there might still be more than 1
    free memory block, but if they are not next to each other, then a channel can't use them
    at the same time. The given $channel_id parameter may be used to force the constructor
    to use a certain channel. Internally, channels always use their own memory block, plus
    the required additional memory blocks. The additional memory blocks come from the channels
    with the next-higher ids.

  ## Example
  Say a program starts by allocating two channels, A and then B.
  It then releases channel A. If the program now wants to allocate a channel with 7 memory blocks, it
    would fail, as there are only 6 continuous memory blocks available.
  The developer could force channel A to use channel id 1, and channel B to use id 0. This way
    releasing channel A would free the second memory block (at location 1) and thus allow the creation
    of a channel with 7 memory blocks.
  */
  constructor .pin/gpio.Pin --memory_block_count/int=1 --channel_id/int?=null:
    resource_ = rmt_channel_new_ resource_group_ memory_block_count (channel_id or -1)

  /**
  Variant of $(constructor pin).

  Configures the channel for input. See $(configure --input) for input parameters.
  */
  constructor --input/bool pin/gpio.Pin --memory_block_count/int=1
      --channel_id /int? = null
      --clk_div /int = DEFAULT_IN_CLK_DIV
      --flags /int = DEFAULT_IN_FLAGS
      --idle_threshold /int = DEFAULT_IN_IDLE_THRESHOLD
      --enable_filter /bool = DEFAULT_IN_ENABLE_FILTER
      --filter_ticks_threshold /int = DEFAULT_IN_FILTER_TICKS_THRESHOLD
      --buffer_size /int = DEFAULT_IN_BUFFER_SIZE:
    if not input: throw "INVALID_ARGUMENT"
    result := Channel pin --memory_block_count=memory_block_count --channel_id=channel_id
    result.configure --input
        --clk_div=clk_div
        --flags=flags
        --idle_threshold=idle_threshold
        --enable_filter=enable_filter
        --filter_ticks_threshold=filter_ticks_threshold
        --buffer_size=buffer_size
    return result

  /**
  Variant of $(constructor pin).

  Configures the channel for output. See $(configure --output) for output parameters.
  */
  constructor --output/bool pin/gpio.Pin --memory_block_count/int=1
      --channel_id /int? = null
      --clk_div /int = DEFAULT_OUT_CLK_DIV
      --flags /int = DEFAULT_OUT_FLAGS
      --enable_carrier /bool = DEFAULT_OUT_ENABLE_CARRIER
      --carrier_frequency_hz /int = DEFAULT_OUT_CARRIER_FREQUENCY
      --carrier_level /int = DEFAULT_OUT_CARRIER_LEVEL
      --carrier_duty_percent /int = DEFAULT_OUT_CARRIER_DUTY_PERCENT
      --idle_level /int? = DEFAULT_OUT_IDLE_LEVEL:
    if not output: throw "INVALID_ARGUMENT"
    result := Channel pin --memory_block_count=memory_block_count --channel_id=channel_id
    result.configure --output
        --clk_div=clk_div
        --flags=flags
        --enable_carrier=enable_carrier
        --carrier_frequency_hz=carrier_frequency_hz
        --carrier_level=carrier_level
        --carrier_duty_percent=carrier_duty_percent
        --idle_level=idle_level
    return result

  /**
  Configures the channel for input.
  - $clk_div is the source clock divider. Must be in the range [0,255].
  - $flags is the configuration flags. See the ESP-IDF documentation for available flags.f
  - $idle_threshold is the number of clock cycles the receiver will run without seeing an edge.
  - $enable_filter is whether the filter is enabled.
  - $filter_ticks_threshold pulses shorter than this value is filtered away.
    Only works with $enable_filter. The value must be in the range [0,255].
  - $buffer_size determines the size in bytes of the receive buffer. It must be bigger than

  # Advanced
  The $clk_div divides the APB (advanced peripheral bus) clock. The APB clock is set to 80MHz.
  The $filter_ticks_threshold counts APB bus ticks. As such, a value of 80 is equivalent to 1us.
  */
  configure --input/bool
      --clk_div /int = DEFAULT_IN_CLK_DIV
      --flags /int = DEFAULT_IN_FLAGS
      --idle_threshold /int = DEFAULT_IN_IDLE_THRESHOLD
      --enable_filter /bool = DEFAULT_IN_ENABLE_FILTER
      --filter_ticks_threshold /int = DEFAULT_IN_FILTER_TICKS_THRESHOLD
      --buffer_size /int = DEFAULT_IN_BUFFER_SIZE:
    if not input: throw "INVALID_ARGUMENT"
    if not resource_: throw "ALREADY_CLOSED"
    rmt_config_rx_ resource_ pin.num clk_div flags idle_threshold enable_filter filter_ticks_threshold buffer_size
    rx_buffer_size_ = buffer_size
    configured_ = 1

  /**
  Configure the channel for output.
  - $clk_div is the source clock divider. Must be in the range [0,255].
  - $flags is the configuration flags. See the ESP-IDF documentation for available flags.
  - $enable_carrier is whether a carrier wave is used.
  - $carrier_frequency_hz is the frequency of the carrier wave.
  - $carrier_level is the way the carrier way is modulated.
    Set to 1 to transmit on low output level and 0 to transmit on high output level.
  - $carrier_duty_percent is the proportion of time the carrier wave is low.
  - $idle_level is the level transmitted by the transmitter when idle. If null, no idle level is output.

  # Advanced
  The $clk_div divides the APB (advanced peripheral bus) clock. The APB clock is set to 80MHz.
  */
  configure --output/bool
      --clk_div /int = DEFAULT_OUT_CLK_DIV
      --flags /int = DEFAULT_OUT_FLAGS
      --enable_carrier /bool = DEFAULT_OUT_ENABLE_CARRIER
      --carrier_frequency_hz /int = DEFAULT_OUT_CARRIER_FREQUENCY
      --carrier_level /int = DEFAULT_OUT_CARRIER_LEVEL
      --carrier_duty_percent /int = DEFAULT_OUT_CARRIER_DUTY_PERCENT
      --idle_level /int? = DEFAULT_OUT_IDLE_LEVEL:
    if not output: throw "INVALID_ARGUMENT"
    if not resource_: throw "ALREADY_CLOSED"
    enable_idle_output := idle_level ? true : false
    idle_level = idle_level or -1
    enable_loop := false
    rmt_config_tx_ resource_ pin.num clk_div flags enable_carrier carrier_frequency_hz carrier_level carrier_duty_percent enable_loop enable_idle_output idle_level
    rx_buffer_size_ = null
    configured_ = 2

  is_configured -> bool:
    return configured_ != 0

  is_input -> bool:
    return configured_ == 1

  is_output -> bool:
    return configured_ == 2

  idle_threshold -> int?:
    return rmt_get_idle_threshold_ resource_

  idle_threshold= threshold/int -> none:
    rmt_set_idle_threshold_ resource_ threshold

  /**
  Returns the buffer size in bytes.

  This value is null if the channel is not configured for input.
  */
  buffer_size -> int?:
    return rx_buffer_size_

  /**
  Receives signals.

  This channel must be configured for receiving (see $(configure --input)).

  If $max_bytes is not sufficient to store all received signals, then the
    result is truncated. If it is important to detect this condition, then the user should
    set $max_bytes to a value greater than the maximum expected signal byte size.

  Warning: currently the receiver is blocking which may cause multiple issues:
  - the watchdog timer might be triggered
  - no global garbage collection can run while the receiver is waiting.

  The $timeout_ms must be big enough for the RMT peripheral to copy the data into its
    internal buffer. At the very least the timeout thus must be bigger than the idle threshold.
    However, because of context switches etc, several milliseconds are usually required
    before the data is available in the internal buffers.
  */
  read max_bytes/int --timeout_ms/int=DEFAULT_READ_TIMEOUT_MS -> Signals:
    if not is_input: throw "INVALID_STATE"
    if max_bytes > buffer_size: throw "maximum returned buffer size greater than allocated buffer size"
    bytes := rmt_receive_ resource_ max_bytes timeout_ms
    return Signals.from_bytes bytes

  /**
  Transmits the given $signals.

  This channel must be configured for writing (see $(configure --output)).
  */
  write signals/Signals -> none:
    if not is_output: throw "INVALID_STATE"
    rmt_transmit_ resource_ signals.bytes_

  /** Closes the channel. */
  close:
    if resource_:
      rmt_channel_delete_ resource_group_ resource_
      resource_ = null
      configured_ = 0
      rx_buffer_size_ = null

/**
A bidirectional channel.

This channel uses two hardware channels to be able to read and write at the same time.
This only makes sense if the pin is set to open-drain mode, as the receiver would otherwise just
  read the output of the output channel. The constructor automatically sets the pin to open-drain.

This class can be used to implement protocols that communicate over one wire, like the 1-wire protocol
  or the one used for DHTxx sensors.
*/
class BidirectionalChannel:
  in_channel_  / Channel
  out_channel_ / Channel

  /**
  Constructs a bidirectional channel.

  This operation at least two hardware channels (one for input and one for output).

  The output channel is configured with a high idle level, and the pin is set to open-drain.

  See $Channel.configure for an explanation on the parameters.
  */
  constructor pin/gpio.Pin
      --clk_div /int = Channel.DEFAULT_CLK_DIV
      --in_channel_id /int = -1
      --in_memory_block_count /int = 1
      --in_clk_div /int = clk_div
      --in_enable_filter /bool = Channel.DEFAULT_IN_ENABLE_FILTER
      --in_filter_ticks_threshold /int = Channel.DEFAULT_IN_FILTER_TICKS_THRESHOLD
      --in_idle_threshold /int = Channel.DEFAULT_IN_IDLE_THRESHOLD
      --in_buffer_size = Channel.DEFAULT_IN_BUFFER_SIZE
      --out_channel_id /int = -1
      --out_memory_block_count /int = 1
      --out_clk_div /int = clk_div:
    in_channel_  = Channel pin --channel_id=in_channel_id --memory_block_count=in_memory_block_count
    out_channel_ = Channel pin --channel_id=out_channel_id --memory_block_count=out_memory_block_count
    out_channel_.configure --output --idle_level=1 --clk_div=out_clk_div
    in_channel_.configure --input
        --clk_div=in_clk_div
        --enable_filter=in_enable_filter
        --filter_ticks_threshold=in_filter_ticks_threshold
        --idle_threshold=in_idle_threshold
        --buffer_size=in_buffer_size
    rmt_config_bidirectional_pin_ out_channel_.pin.num out_channel_.resource_

  /**
  Transmits the given $signals.

  See $Channel.write.
  */
  write signals/Signals -> none:
    out_channel_.write signals

  /**
  Receives $max_bytes items.

  See $Channel.read.
  */
  read max_bytes/int --timeout_ms/int=Channel.DEFAULT_READ_TIMEOUT_MS -> Signals:
    return in_channel_.read max_bytes --timeout_ms=timeout_ms

  /**
  Transmits the given signals while simultaneously receiving.

  First transmits the $before_read signals. Then starts receiving and
    emits the $during_read signals.

  The given $max_bytes specifies the maximum byte size of the returned
    signals. The $max_bytes must be smaller than the configured
    buffer size for receiving.

  If $max_bytes is not sufficient to store all received signals, then the
    result is truncated. If it is important to detect this condition, then the user should
    set $max_bytes to a value greater than the maximum expected signal byte size.

  The $timeout_ms must be big enough for the RMT peripheral to copy the data into its
    internal buffer. At the very least the timeout thus must be bigger than the idle threshold.
    However, because of context switches etc, several milliseconds are usually required
    before the data is available in the internal buffers.
  The $timeout_ms only starts counting after the $during_read signals have been emitted. It is
    not necessary to include the duration of them.
  */
  write_and_read -> Signals
      --before_read/Signals=Signals.ZERO
      --during_read/Signals=Signals.ZERO
      max_bytes/int
      --timeout_ms/int=Channel.DEFAULT_READ_TIMEOUT_MS:
    if max_bytes > in_channel_.buffer_size: throw "maximum returned buffer size greater than allocated buffer size"
    result := rmt_transmit_and_receive_
        out_channel_.resource_
        in_channel_.resource_
        before_read.bytes_
        during_read.bytes_
        max_bytes
        timeout_ms
    return Signals.from_bytes result

  /**
  Returns the idle threshold of the input channel.

  See $Channel.idle_threshold.
  */
  idle_threshold -> int:
    return in_channel_.idle_threshold

  /**
  Sets the idle threshold of the input channel.

  See $Channel.idle_threshold=.
  */
  idle_threshold= new_value/int:
    in_channel_.idle_threshold = new_value

  close:
    in_channel_.close
    out_channel_.close

resource_group_ ::= rmt_init_

rmt_init_:
  #primitive.rmt.init

rmt_channel_new_ resource_group memory_block_count channel_num:
  #primitive.rmt.channel_new

rmt_channel_delete_ resource_group resource:
  #primitive.rmt.channel_delete

rmt_config_rx_ resource/ByteArray pin_num/int clk_div/int flags/int
    idle_threshold/int filter_en/bool filter_ticks_thresh/int rx_buffer_size/int:
  #primitive.rmt.config_rx

rmt_config_tx_ resource/ByteArray pin_num/int clk_div/int flags/int
    carrier_en/bool carrier_freq_hz/int carrier_level/int carrier_duty_percent/int
    loop_en/bool idle_output_en/bool idle_level/int:
  #primitive.rmt.config_tx

rmt_set_idle_threshold_ resource/ByteArray threshold/int:
  #primitive.rmt.set_idle_threshold

rmt_get_idle_threshold_ resource/ByteArray -> int:
  #primitive.rmt.get_idle_threshold

rmt_config_bidirectional_pin_ pin/int tx_resource/ByteArray:
  #primitive.rmt.config_bidirectional_pin

rmt_transmit_ tx_resource/ByteArray signals_bytes/*/Blob*/:
  #primitive.rmt.transmit

rmt_receive_ rx_resource/ByteArray max_output_len/int receive_timeout/int:
  #primitive.rmt.receive

rmt_transmit_and_receive_ tx_resource/ByteArray rx_resource/ByteArray transmit_bytes/*/Blob*/ receive_bytes max_output_len/int receive_timeout/int:
  #primitive.rmt.transmit_and_receive
