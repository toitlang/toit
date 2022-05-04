// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import binary show LITTLE_ENDIAN

/**
Support for the ESP32 Remote Control (RMT).

A $Channel corresponds to a channel in the ESP32 RMT controller.

$Signals represent a collection of signals to be sent by the RMT controller.

# Examples

## Pulse
Emits a precisely timed pulse of 50us on pin 18.
```
import gpio
import rmt

main:
  pin := gpio.Pin 18
  channel := rmt.Channel pin --output --idle_level=0
  pulse := rmt.Signals 1
  pulse.set 0 --level=1 --duration=50
  channel.write pulse
  channel.close
```
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

  stringify -> string:
    result := ""
    do: | level period |
      if result != "": result += " "
      result += "$level-$period"
    return result

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
  static DEFAULT_OUT_CLK_DIV ::= DEFAULT_CLK_DIV
  static DEFAULT_OUT_FLAGS ::= 0
  static DEFAULT_OUT_ENABLE_CARRIER ::= false
  static DEFAULT_OUT_CARRIER_FREQUENCY ::= 38000
  static DEFAULT_OUT_CARRIER_LEVEL ::= 1
  static DEFAULT_OUT_CARRIER_DUTY_PERCENT ::= 33
  static DEFAULT_OUT_IDLE_LEVEL ::= null

  pin       /gpio.Pin
  resource_ /ByteArray? := ?

  static NOT_CONFIGURED_ ::= 0
  static CONFIGURED_AS_INPUT_ ::= 1
  static CONFIGURED_AS_OUTPUT_ ::= 2
  configured_ /int := NOT_CONFIGURED_

  /** Whether the channel has started reading with $start_reading. */
  is_reading_ /bool := false

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

  Generally, output channels don't need extra blocks as interrupts will copy data into
    the buffer when necessary. However, input channels can only receive as many signals
    (in one sequence) as there is space in the memory blocks.

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
      --buffer_size /int? = null:
    if not input: throw "INVALID_ARGUMENT"
    if not 1 <= memory_block_count <= 8: throw "INVALID_ARGUMENT"

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
    if not 1 <= memory_block_count <= 8: throw "INVALID_ARGUMENT"

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

  The $clk_div divides the 80MHz clock. The value must be in range [1, 255].
  The RMT unit works with ticks. All sent and received signals count ticks.

  The $flags can be found in the ESP-IDF documentation.

  The $idle_threshold determines how many ticks the channel must not change before it is
    considered idle (and thus finishes a signal sequence). The value must be in
    range [1, 32767] (15 bits).

  If $enable_filter is set, discards signals that are shorter than $filter_ticks_threshold.
    Contrary to most other parameters, the filter counts the APB ticks and not the
    divided clock ticks. The value must be in range [0, 255].

  The $buffer_size determines how many signals can be buffered before the channel is
    considered full. This buffer is used internally to copy signals from the RMT
    memory blocks (which have been reserved in the constructor) to user code.

  The maximum size of any item in this buffer is less than half of the buffer size.
    This means that the buffer should be 8 bytes + the maximum expected size (which
    must be a multiple of 4, as each signal is handled in pairs of 16 bits).

  By default it is set to twice the size of the reserved memory blocks (which limit
    the size of the received signal sequence). However, due to the book-keeping overhead
    this means that some very long signal sequences can not be received. If necessary,
    adjust to a bigger size.

  If the input is well known and has a limited size it's ok to request a smaller size.
    In that case request at least twice the expected size + 8.

  Another use case, where bigger buffers are necessary, is when the input can receive
    multiple sequences where the handling of the data might not be fast enough. In that
    case, too, it is necessary to increase the buffer size.
  */
  configure --input/bool
      --clk_div /int = DEFAULT_IN_CLK_DIV
      --flags /int = DEFAULT_IN_FLAGS
      --idle_threshold /int = DEFAULT_IN_IDLE_THRESHOLD
      --enable_filter /bool = DEFAULT_IN_ENABLE_FILTER
      --filter_ticks_threshold /int = DEFAULT_IN_FILTER_TICKS_THRESHOLD
      --buffer_size /int? = null:
    if not input: throw "INVALID_ARGUMENT"
    if not resource_: throw "ALREADY_CLOSED"
    if not 1 <= clk_div <= 0xFF: throw "INVALID_ARGUMENT"
    if not 1 <= idle_threshold <=0x7FFF: throw "INVALID_ARGUMENT"
    if enable_filter and not 0 <= filter_ticks_threshold <= 0xFF: throw "INVALID_ARGUMENT"
    if buffer_size and buffer_size < 1: throw "INVALID_ARGUMENT"

    rmt_config_rx_ resource_ pin.num clk_div flags idle_threshold enable_filter filter_ticks_threshold (buffer_size or -1)
    configured_ = CONFIGURED_AS_INPUT_

  /**
  Configures the channel for output.

  The $clk_div divides the 80MHz clock. The value must be in range [1, 255].
  The RMT unit works with ticks. All sent and received signals count ticks.

  The $flags can be found in the ESP-IDF documentation.
  When the carrier is enabled ($enable_carrier) the output signal is a square wave that
    is modulated by the pulses. In that case the clock frequency (80MHz) is divided by the
    $carrier_frequency_hz, yielding duty units. These are then divided according to the
    $carrier_duty_percent.
  The $carrier_level indicates at which level of the RMT pulses the carrier (and thus any
    output) is enabled. When set to 1 transmits on low output level, and when equal to 0
    transmits on high output level.

  The $idle_level is the level that the channel is set to when it is idle.
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
    if not 1 <= clk_div <= 255: throw "INVALID_ARGUMENT"
    if idle_level != null and idle_level != 0 and idle_level != 1: throw "INVALID_ARGUMENT"
    if enable_carrier:
      if carrier_frequency_hz < 1: throw "INVALID_ARGUMENT"
      if not 1 <= carrier_duty_percent <= 100: throw "INVALID_ARGUMENT"
      if carrier_level != 0 and carrier_level != 1: throw "INVALID_ARGUMENT"

    enable_idle_output := idle_level ? true : false
    idle_level = idle_level or -1
    enable_loop := false
    rmt_config_tx_ resource_ pin.num clk_div flags enable_carrier carrier_frequency_hz carrier_level carrier_duty_percent enable_loop enable_idle_output idle_level
    configured_ = CONFIGURED_AS_OUTPUT_

  /**
  Takes the $in and $out channel that share the same pin and configures them to be
    bidirectional.

  The $out channel must be configured as output (see $(configure --output)) and must
    have been configured before the $in channel, which must be configured as input (see
    $(configure --input)).

  Sets the pin to open-drain, as the input channel would otherwise just read the signals of
    the output channel.

  This function can be used to implement protocols that communicate over one wire, like
    the 1-wire protocol or the one used for DHTxx sensors.

  Any new call to $configure requires a new call to this function.
  */
  static make_bidirectional --in/Channel --out/Channel:
    if not in.is_input or not out.is_output: throw "INVALID_STATE"
    if in.pin.num != out.pin.num: throw "INVALID_ARGUMENT"
    rmt_config_bidirectional_pin_ out.pin.num out.resource_

  is_configured -> bool:
    return configured_ != NOT_CONFIGURED_

  is_input -> bool:
    return configured_ == CONFIGURED_AS_INPUT_

  is_output -> bool:
    return configured_ == CONFIGURED_AS_OUTPUT_

  idle_threshold -> int?:
    return rmt_get_idle_threshold_ resource_

  idle_threshold= threshold/int -> none:
    if not 1 <= threshold <=0x7FFF: throw "INVALID_ARGUMENT"
    rmt_set_idle_threshold_ resource_ threshold

  is_reading -> bool:
    return is_reading_

  /**
  Starts receiving signals for this channel.

  This channel must be configured for receiving (see $(configure --input)).

  If $flush is set (the default) flushes all buffered signals.
  */
  start_reading --flush/bool=true -> none:
    if not is_input: throw "INVALID_STATE"
    is_reading_ = true
    rmt_start_receive_ resource_ flush

  /**
  Stops receiving.
  */
  stop_reading -> none:
    is_reading_ = false
    rmt_stop_receive_ resource_

  /**
  Receives signals.

  This channel must be configured for receiving (see $(configure --input)).

  The result may contain trailing 0-period signals. Those should be ignored.

  If the channel hasn't yet started to read, starts reading ($start_reading).
    However, does not flush

  If $stop_reading is true, stops reading after the next signal is received.
  If $stop_reading is false, always keeps the channel reading.
  If $stop_reading is null, stops reading if the channel wasn't reading yet.
  */
  read --stop_reading/bool?=null -> Signals:
    if not is_input: throw "INVALID_STATE"

    was_reading := is_reading_
    if stop_reading == null: stop_reading = not was_reading

    if not was_reading: start_reading
    // Increase sleep time over time.
    // TODO(florian): switch to an event-based model.
    // Note that reading could take at worst almost a minute:
    // If the channel uses all 8 memory blocks, it can receive 8 * 64 signals.
    // Each signal can count 2^15 ticks. If the clock (80MHz) is furthermore divided
    // by 255 (the max), then reading can take a long time...
    sleep_time := 1
    try:
      // Let the system prepare a buffer we will use to write the received data into.
      bytes := rmt_prepare_receive_ resource_
      while true:
        result := rmt_receive_ resource_ bytes true
        if result: return Signals.from_bytes result
        sleep --ms=sleep_time
        if sleep_time < 10: sleep_time++
        else if sleep_time < 100: sleep_time *= 2
    finally:
      if stop_reading: this.stop_reading

  /**
  Transmits the given $signals.

  This channel must be configured for writing (see $(configure --output)).
  */
  write signals/Signals -> none:
    if not is_output: throw "INVALID_STATE"

    // Start sending the data.
    // We receive a write_buffer with external memory that we need to keep alive
    // until the sending is done. This buffer may be the $signals.bytes_ buffer
    // if that one is external.
    buffer := rmt_transmit_ resource_ signals.bytes_

    // Increase sleep time over time.
    // TODO(florian): switch to an event-based model.
    // Note that the signal size is not limited, and that writing
    //   the signals can take significant time.
    sleep_time := 1
    // Send the buffer, to ensure that the compiler doesn't optimize the local variable away.
    while not rmt_transmit_done_ resource_ buffer:
      sleep --ms=sleep_time
      if sleep_time < 10: sleep_time++
      else if sleep_time < 100: sleep_time *= 2

  // TODO(florian): add a `write --loop`.
  // This function can only take a limited amount of memory (contrary to $write).
  // It should copy the data into the internal buffers, and then reconfigure the channel.

  /** Closes the channel. */
  close:
    if resource_:
      rmt_channel_delete_ resource_group_ resource_
      resource_ = null
      configured_ = 0

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

rmt_transmit_ resource/ByteArray signals_bytes/*/Blob*/:
  #primitive.rmt.transmit

rmt_transmit_done_ resource/ByteArray signals_bytes/*/Blob*/:
  #primitive.rmt.transmit_done

rmt_start_receive_ resource/ByteArray flush/bool:
  #primitive.rmt.start_receive

rmt_stop_receive_ resource/ByteArray:
  #primitive.rmt.stop_receive

rmt_prepare_receive_ resource/ByteArray -> ByteArray:
  #primitive.rmt.prepare_receive

rmt_receive_ resource/ByteArray target/ByteArray resize/bool:
  #primitive.rmt.receive
