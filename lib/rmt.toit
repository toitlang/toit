// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import io show LITTLE-ENDIAN
import system

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
  // Create a channel on pin 18 with a resolution of 1MHz.
  channel := rmt.Channel pin --output --resolution=1_000_000
  pulse := rmt.Signals 2
  pulse.set 0 --level=1 --period=50  // In ticks of the specified resolution.
  pulse.set 1 --level=1 --period=50
  channel.write pulse --done-level=0
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
*/
class Signals:
  /** Bytes per ESP32 signal. */
  static BYTES-PER-SIGNAL ::= 2

  /** The maximum period of a signal, in ticks. */
  static MAX-PERIOD ::= 0x7FFF

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
    $size * $BYTES-PER-SIGNAL.
  */
  // TODO(florian): take a clock-divider as argument and allow the user to specify
  // durations in us. Then also add a `do --us-periods:`.
  constructor .size:
    bytes_ = ByteArray
        round-up (size * 2) 4
    // Terminate the signals with a high end-marker. The duration 0 signals the
    // end of the sequence, but with a level equal to 0 the peripheral would still
    // emit a short pulse when its pin is set to open-drain.
    // See https://github.com/espressif/esp-idf/issues/8864
    if size % 2 == 1: set-signal_ size 0 1

  /**
  Creates signals that alternate between a level of 0 and 1 with the periods
    given in the $periods list.

  The level of the first signal is $first-level.
  */
  constructor.alternating --first-level/int periods/List:
    if first-level != 0 and first-level != 1: throw "INVALID_ARGUMENT"

    return Signals.alternating periods.size --first-level=first-level: | idx |
      periods[idx]

  /**
  Creates items that alternate between a level of 0 and 1 with the periods
    given by successive calls to the block.

  The $block is called with the signal index and the level it is created with.

  The level of the first signal is $first-level.
  */
  constructor.alternating size/int --first-level/int [block]:
    if first-level != 0 and first-level != 1: throw "INVALID_ARGUMENT"

    signals := Signals size
    level := first-level
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
  constructor.from-bytes bytes/ByteArray:
    if bytes.size % 4 != 0: throw "INVALID_ARGUMENT"

    bytes_ = bytes
    size = bytes_.size / 2

  /**
  Returns the signal period of the $i'th signal.

  The given $i must be in the range [0..$size[.
  */
  period i/int -> int:
    check-bounds_ i
    return signal-period_ i

  /**
  Returns the signal level of the $i'th signal.

  The given $i must be in the range [0..$size[.
  */
  level i/int -> int:
    check-bounds_ i
    return signal-level_ i

  /**
  Sets the $i'th signal to the given $period and $level.

  The given $i must be in the range [0..$size[.

  The given $period must be in the range [0..0x7FFF].

  The given $level must be 0 or 1.
  */
  set i/int --period/int --level/int -> none:
    check-bounds_ i
    set-signal_ i period level

  set-signal_ i/int period/int level/int -> none:
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
        signal-level_ it
        signal-period_ it

  check-bounds_ i:
    if not 0 <= i < size: throw "OUT_OF_BOUNDS"

  signal-level_ i -> int:
    return bytes_[i * 2 + 1] >> 7

  signal-period_ i -> int:
    idx := i * 2
    return (LITTLE-ENDIAN.uint16 bytes_ idx) & 0x7fff

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

Deprecated. Use $In and $Out instead.
*/
class Channel:
  static DEFAULT-CLK-DIV ::= 80
  static DEFAULT-IN-CLK-DIV ::= DEFAULT-CLK-DIV
  static DEFAULT-IN-IDLE-THRESHOLD ::= 12000
  static DEFAULT-IN-ENABLE-FILTER ::= true
  static DEFAULT-IN-FILTER-TICKS-THRESHOLD ::= 100
  static DEFAULT-IN-FLAGS ::= 0
  static DEFAULT-OUT-CLK-DIV ::= DEFAULT-CLK-DIV
  static DEFAULT-OUT-FLAGS ::= 0
  static DEFAULT-OUT-ENABLE-CARRIER ::= false
  static DEFAULT-OUT-CARRIER-FREQUENCY ::= 38000
  static DEFAULT-OUT-CARRIER-LEVEL ::= 1
  static DEFAULT-OUT-CARRIER-DUTY-PERCENT ::= 33
  static DEFAULT-OUT-IDLE-LEVEL ::= null

  channel_/Channel_? := null

  // Configuration.
  pin/gpio.Pin
  input_/bool := false
  memory-block-count_/int := 0
  clk-div_/int := 0
  idle-threshold_/int := 0
  enable-filter_/bool := true
  filter-ticks-threshold_/int := 0
  open-drain_/bool := false
  idle-level_/int := 0
  enable-carrier_/bool := false
  carrier-frequency-hz_/int := 0
  carrier-level_/int := 0
  carrier-duty-percent_/int := 0
  pull-up_/bool := false

  /**
  Constructs a channel using the given $num using the given $pin.

  Note: only the ESP32 and the ESP32S2 support configuring the channel direction at a later
    time. For all other platforms, this constructor will give a TX channel, unless
    the channel-id is provided.

  The $memory-block-count determines how many memory blocks are assigned to this channel. See
    the Advanced section for more information.

  The $channel-id should generally be left as default. If provided, it selects the
    channel with that physical id. On a standard ESP32, there are 8 channels which can be
    selected by providing a channel id in the range [0,7]. See the advanced section for
    when this can be useful.

  This constructor does not configure the channel for input or output yet. Call $configure
    (either `--input` or `--output`) to do so.

  Deprecated. Use the `--input` or `--output` constructor instead.

  # Advanced

  The $memory-block-count determines how many memory blocks are assigned to this channel.
    Memory blocks are of size 256 bytes or 128 signals. They are in continuous memory and
    there are only a limited number of them.

  Generally, output channels don't need extra blocks as interrupts will copy data into
    the buffer when necessary. However, input channels can only receive as many signals
    (in one sequence) as there is space in the memory blocks.

  If a channel requests more than one memory block, then the following internal channel id is
    marked as used as well.

  Users might run into fragmentation issues as well: there might still be more than 1
    free memory block, but if they are not next to each other, then a channel can't use them
    at the same time. The given $channel-id parameter may be used to force the constructor
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
  constructor .pin/gpio.Pin --memory-block-count/int=1 --channel-id/int?=null:
    memory-block-count_ = memory-block-count

  /**
  Variant of $(constructor pin).

  Configures the channel for input. See $(configure --input) for input parameters.
  */
  constructor --input/bool .pin/gpio.Pin --memory-block-count/int=1
      --channel-id /int? = null
      --clk-div /int = DEFAULT-IN-CLK-DIV
      --flags /int = DEFAULT-IN-FLAGS
      --idle-threshold /int = DEFAULT-IN-IDLE-THRESHOLD
      --enable-filter /bool = DEFAULT-IN-ENABLE-FILTER
      --filter-ticks-threshold /int = DEFAULT-IN-FILTER-TICKS-THRESHOLD
      --buffer-size /int? = null:
    if not input: throw "INVALID_ARGUMENT"
    if not 1 <= memory-block-count <= 8: throw "INVALID_ARGUMENT"

    memory-block-count_ = memory-block-count
    configure --input
        --clk-div=clk-div
        --flags=flags
        --idle-threshold=idle-threshold
        --enable-filter=enable-filter
        --filter-ticks-threshold=filter-ticks-threshold
        --buffer-size=buffer-size

  /**
  Variant of $(constructor pin).

  Configures the channel for output. See $(configure --output) for output parameters.
  */
  constructor --output/bool .pin/gpio.Pin --memory-block-count/int=1
      --channel-id /int? = null
      --clk-div /int = DEFAULT-OUT-CLK-DIV
      --flags /int = DEFAULT-OUT-FLAGS
      --enable-carrier /bool = DEFAULT-OUT-ENABLE-CARRIER
      --carrier-frequency-hz /int = DEFAULT-OUT-CARRIER-FREQUENCY
      --carrier-level /int = DEFAULT-OUT-CARRIER-LEVEL
      --carrier-duty-percent /int = DEFAULT-OUT-CARRIER-DUTY-PERCENT
      --idle-level /int? = DEFAULT-OUT-IDLE-LEVEL:
    if not output: throw "INVALID_ARGUMENT"
    if not 1 <= memory-block-count <= 8: throw "INVALID_ARGUMENT"

    memory-block-count_ = memory-block-count
    configure --output
        --clk-div=clk-div
        --flags=flags
        --enable-carrier=enable-carrier
        --carrier-frequency-hz=carrier-frequency-hz
        --carrier-level=carrier-level
        --carrier-duty-percent=carrier-duty-percent
        --idle-level=idle-level

  /**
  Configures the channel for input.

  Only some chips (for example ESP32 and ESP32S2) support configuring the channel direction
    at a later time. For all other platforms changing direction will throw.

  The $clk-div divides the 80MHz clock. The value must be in range [1, 255].
  The RMT unit works with ticks. All sent and received signals count ticks.

  The $flags can be found in the ESP-IDF documentation.

  The $idle-threshold determines how many ticks the channel must not change before it is
    considered idle (and thus finishes a signal sequence). The value must be in
    range [1, 32767] (15 bits).

  If $enable-filter is set, discards signals that are shorter than $filter-ticks-threshold.
    Contrary to most other parameters, the filter counts the APB ticks and not the
    divided clock ticks. The value must be in range [0, 255].

  The $buffer-size determines how many signals can be buffered before the channel is
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
      --clk-div /int = DEFAULT-IN-CLK-DIV
      --flags /int = DEFAULT-IN-FLAGS
      --idle-threshold /int = DEFAULT-IN-IDLE-THRESHOLD
      --enable-filter /bool = DEFAULT-IN-ENABLE-FILTER
      --filter-ticks-threshold /int = DEFAULT-IN-FILTER-TICKS-THRESHOLD
      --buffer-size /int? = null:
    if not input: throw "INVALID_ARGUMENT"
    if not 1 <= clk-div <= 0xFF: throw "INVALID_ARGUMENT"
    if not 1 <= idle-threshold <= Signals.MAX-PERIOD: throw "INVALID_ARGUMENT"
    if enable-filter and not 0 <= filter-ticks-threshold <= 0xFF: throw "INVALID_ARGUMENT"
    if buffer-size and buffer-size < 1: throw "INVALID_ARGUMENT"

    // Not clear what happened, but in the old API it was apparently possible to have
    // a ringbuffer into which the RMT would write when the hw buffer was full. This
    // doesn't seem to be the case anymore. To have some backward compatibility we
    // increase the buffer size to the size of the memory blocks.
    if buffer-size and buffer-size > memory-block-count_ * BYTES-PER-MEMORY-BLOCK:
      memory-block-count_ = buffer-size / BYTES-PER-MEMORY-BLOCK
    if memory-block-count_ > 4 and system.architecture != system.ARCHITECTURE-ESP32:
      memory-block-count_ = 4

    input_ = true
    pull-up_ = false
    clk-div_ = clk-div
    idle-threshold_ = idle-threshold
    enable-filter_ = enable-filter
    filter-ticks-threshold_ = filter-ticks-threshold

    create-new-channel_

  /**
  Configures the channel for output.

  Only some chips (for example ESP32 and ESP32S2) support configuring the channel direction
    at a later time. For all other platforms changing direction will throw.

  The $clk-div divides the 80MHz clock. The value must be in range [1, 255].
  The RMT unit works with ticks. All sent and received signals count ticks.

  The $flags can be found in the ESP-IDF documentation.
  When the carrier is enabled ($enable-carrier) the output signal is a square wave that
    is modulated by the pulses. In that case the clock frequency (80MHz) is divided by the
    $carrier-frequency-hz, yielding duty units. These are then divided according to the
    $carrier-duty-percent.
  The $carrier-level indicates at which level of the RMT pulses the carrier (and thus any
    output) is enabled. When set to 1 transmits on low output level, and when equal to 0
    transmits on high output level.

  The $idle-level is the level that the channel is set to when it is idle.
  */
  configure --output/bool
      --clk-div /int = DEFAULT-OUT-CLK-DIV
      --flags /int = DEFAULT-OUT-FLAGS
      --enable-carrier /bool = DEFAULT-OUT-ENABLE-CARRIER
      --carrier-frequency-hz /int = DEFAULT-OUT-CARRIER-FREQUENCY
      --carrier-level /int = DEFAULT-OUT-CARRIER-LEVEL
      --carrier-duty-percent /int = DEFAULT-OUT-CARRIER-DUTY-PERCENT
      --idle-level /int? = DEFAULT-OUT-IDLE-LEVEL:
    if not output: throw "INVALID_ARGUMENT"
    if not 1 <= clk-div <= 255: throw "INVALID_ARGUMENT"
    if idle-level != null and idle-level != 0 and idle-level != 1: throw "INVALID_ARGUMENT"
    if enable-carrier:
      if carrier-frequency-hz < 1: throw "INVALID_ARGUMENT"
      if not 1 <= carrier-duty-percent <= 100: throw "INVALID_ARGUMENT"
      if carrier-level != 0 and carrier-level != 1: throw "INVALID_ARGUMENT"

    input_ = false
    clk-div_ = clk-div
    enable-carrier_ = enable-carrier
    carrier-frequency-hz_ = carrier-frequency-hz
    carrier-level_ = carrier-level
    carrier-duty-percent_ = carrier-duty-percent
    idle-level_ = idle-level
    open-drain_ = false

    create-new-channel_

  create-new-channel_:
    if channel_: channel_.close

    hw-signals := memory-block-count_ * 128
    resolution := 80_000_000 / clk-div_
    if input_:
      channel_ = In pin --resolution=resolution --memory-blocks=memory-block-count_
    else:
      channel_ = Out pin --resolution=resolution --memory-blocks=memory-block-count_ --open-drain=open-drain_ --pull-up=pull-up_
      if enable-carrier_:
        channel_.apply-carrier carrier-frequency-hz_
            --duty-factor=(carrier-duty-percent_/100.0)
            --active-low=(carrier-level_ == 0)
            --always-on=false


  /**
  Deprecated. Create an $In channel first, then create an $Out channel with the
    `--open-drain` flag on the same pin, instead.

  Takes the $in and $out channel that share the same pin and configures them to be
    bidirectional.

  The $out channel must be configured as output (see $(configure --output)) and must
    have been configured before the $in channel, which must be configured as input (see
    $(configure --input)).

  Sets the pin to open-drain, as the input channel would otherwise just read the signals of
    the output channel.

  If $pull-up is true, then the internal pull-up is enabled.

  This function can be used to implement protocols that communicate over one wire, like
    the 1-wire protocol or the one used for DHTxx sensors.

  Any new call to $configure requires a new call to this function.
  */
  static make-bidirectional --in/Channel --out/Channel --pull-up/bool=false:
    // The output channel must be initialized second now.
    in.channel_.close
    out.channel_.close

    in.create-new-channel_

    out.open-drain_ = true
    out.pull-up_ = pull-up
    out.create-new-channel_

    signals := Signals 2
    signals.set 0 --period=0 --level=out.idle-level_
    signals.set 1 --period=0 --level=out.idle-level_
    out.write signals

  is-configured -> bool:
    return channel_ != null

  is-input -> bool:
    return channel_ != null and channel_ is In

  is-output -> bool:
    return channel_ != null and channel_ is Out

  idle-threshold -> int?:
    return idle-threshold_

  idle-threshold= threshold/int -> none:
    idle-threshold_ = threshold

  is-reading -> bool:
    return channel_ is In and (channel_ as In).is-reading

  /**
  Starts receiving signals for this channel.

  This channel must be configured for receiving (see $(configure --input)).

  If $flush is set (the default) flushes all buffered signals.
  */
  start-reading --flush/bool=true -> none:
    if not is-input: throw "INVALID_STATE"
    if is-reading: stop-reading
    min-ns := 0
    if enable-filter_:
      // The filter runs on the 80MHz clock.
      // A tick's duration in ns is 1000_000_000 / 80_000_000
      min-ns = filter-ticks-threshold_ * 100 / 8
    // A signal tick's duration in ns is 1000_000_000 / (80_000_000 / clk-div_).
    max-ns := idle-threshold_ * (100 * clk-div_ / 8)
    (channel_ as In).start-reading --min-ns=min-ns --max-ns=max-ns

  /**
  Stops receiving.
  */
  stop-reading -> none:
    channel_.reset

  /**
  Receives signals.

  This channel must be configured for receiving (see $(configure --input)).

  The result may contain trailing 0-period signals. Those should be ignored.

  If the channel hasn't yet started to read, starts reading ($start-reading).
    However, does not flush

  If $stop-reading is true, stops reading after the next signal is received.
  If $stop-reading is false, always keeps the channel reading.
  If $stop-reading is null, stops reading if the channel wasn't reading yet.
  */
  read --stop-reading/bool?=null -> Signals:
    if not is-input: throw "INVALID_STATE"

    in := channel_ as In
    was-reading := in.is-reading
    if not was-reading: start-reading

    result := in.wait-for-data

    if stop-reading == false or (stop-reading == null and was-reading):
      // This is a work-around. We don't have a way to really keep the channel reading.
      start-reading

    return result

  /**
  Transmits the given $signals.

  This channel must be configured for writing (see $(configure --output)).
  */
  write signals/Signals -> none:
    if not is-output: throw "INVALID_STATE"

    out := channel_ as Out
    out.write signals --flush --done-level=idle-level_

  /** Closes the channel. */
  close:
    if channel_:
      channel_.close
      channel_ = null

/**
The number of bytes per memory block.

On the ESP32 and ESP32S2 it is 256.
On the ESP32C3, ESP32C6, and ESP32S3 it is 192.
*/
BYTES-PER-MEMORY-BLOCK/int ::= rmt-bytes-per-memory-block_

/**
An RMT channel.
*/
abstract class Channel_:
  static CHANNEL-KIND-INPUT_ ::= 0
  static CHANNEL-KIND-OUTPUT_ ::= 1
  static CHANNEL-KIND-OUTPUT-OPEN-DRAIN_ ::= 2

  state_/ResourceState_

  resource_ /ByteArray? := ?

  constructor.from-sub_ .resource_:
    state_ = ResourceState_ resource-group_ resource_
    reset

  /** Closes the channel. */
  close -> none:
    if not resource_: return
    critical-do:
      state_.dispose
      rmt-channel-delete_ resource-group_ resource_
      resource_ = null

  /**
  Resets the channel.

  If the channel was reading or writing, these operations are aborted and the
    corresponding resources are released.
  */
  reset -> none:
    critical-do --no-respect-deadline:
      rmt-disable_ resource_
      rmt-enable_ resource_

  /**
  Applies a carrier signal to the channel.

  If $active-low is true, the carrier is applied when the signal is low. Otherwise (the default)
    the carrier is applied when the signal is high.

  The $always-on parameter indicates whether the carrier is always applied, or only when
    signals are being sent. In other words, whether the carrier is also applied to the idle
    level. The ESP32 RMT controller *always* applies the carrier to the idle level, even if
    this parameter is set to false. This is a limitation of the hardware.
  */
  apply-carrier frequency-hz/int --duty-factor/float --active-low/bool=false --always-on/bool=false -> none:
    if frequency-hz <= 0: throw "INVALID_ARGUMENT"
    if not 0.0 <= duty-factor <= 1.0: throw "INVALID_ARGUMENT"
    rmt-apply-carrier_ resource_ frequency-hz duty-factor active-low always-on

  disable-carrier -> none:
    rmt-apply-carrier_ resource_ 0 0.0 false false

/**
An RMT input channel.
*/
class In extends Channel_:
  /** Whether the channel has started reading with $start-reading. */
  is-reading_ /bool := false

  /** The number of memory-blocks. */
  memory-blocks_/int

  /**
  Constructs an input channel on the given $pin.

  The $resolution is the frequency of the clock that the RMT controller uses to
    sample the input signal. It ranges from 312500Hz (312.5KHz) to 80000000Hz (80MHz).

  The $memory-blocks parameter specifies how many RMT memory blocks are assigned to this channel.
    Each memory-block has $BYTES-PER-MEMORY-BLOCK bytes. They are in continuous memory and
    there are only a limited number of them. Since each signal is 2 bytes long, the number of
    signals that can be received is $memory-blocks * $BYTES-PER-MEMORY-BLOCK / 2.

  Input channels can only receive as many signals (in one sequence) as there is space
    in the memory blocks.
  */
  constructor pin/gpio.Pin
      --resolution/int
      --memory-blocks/int=1:
    if not 1 <= memory-blocks: throw "INVALID_ARGUMENT"

    memory-blocks_ = memory-blocks
    // Each hw symbol is 4 bytes (2 signals).
    hw-symbols := (memory-blocks * BYTES-PER-MEMORY-BLOCK) >> 2
    resource := rmt-channel-new_ resource-group_ pin.num resolution hw-symbols Channel_.CHANNEL-KIND-INPUT_
    super.from-sub_ resource

  /** Closes the channel. */
  close -> none:
    if not resource_: return
    critical-do:
      state_.dispose
      rmt-channel-delete_ resource-group_ resource_
      resource_ = null

  reset -> none:
    super
    is-reading_ = false

  is-reading -> bool:
    return is-reading_

  /**
  Starts receiving signals for this channel.

  The $min-ns and $max-ns parameters specify the minimum and maximum duration of the
    signals to be received. Any signal that is shorter than $min-ns is ignored.
    If the level of the line stays the same for longer than the $max-ns, the
    reception is stopped and the received signals are returned.

  The $min-ns is intended for glitch filtering and is limited to very small values (3200ns).

  The $max-signal-count parameter specifies the maximum number of signals that can be
    received. If not specified, uses the maximum number of signals that can fit into
    the memory blocks that were specified during construction.

  The $min-ns and $max-ns parameters specify the minimum and maximum duration of a signal
    in nanoseconds. The $max-signal-count parameter specifies the maximum number of signals
    that can be received. If it is not specified, it defaults to the number of signals that
    can be received in the memory blocks.
  */
  start-reading --min-ns/int=0 --max-ns/int --max-signal-count/int?=null -> none:
    hw-signals := memory-blocks_ * BYTES-PER-MEMORY-BLOCK / Signals.BYTES-PER-SIGNAL
    if not max-signal-count: max-signal-count = hw-signals
    if is-reading_: throw "INVALID_STATE"
    if not 0 <= max-signal-count <= hw-signals: throw "INVALID_ARGUMENT"
    if not 0 <= min-ns <= max-ns: throw "INVALID_ARGUMENT"

    is-reading_ = true
    state_.clear-state READ-STATE_
    max-bytes := max-signal-count * 2
    rmt-start-receive_ resource_ min-ns max-ns max-bytes

  /**
  Reads the signals that have been received.

  Requires a call to $start-reading.
  */
  wait-for-data -> Signals:
    if not is-reading_: throw "INVALID_STATE"

    while true:
      state_.clear-state READ-STATE_
      result := rmt-receive_ resource_
      if result:
        is-reading_ = false
        return Signals.from-bytes result
      // No data yet.
      state_.wait-for-state READ-STATE_

  /**
  Receives signals.

  This is a convenience function that calls $start-reading and $wait-for-data.
  */
  read --min-ns/int=0 --max-ns/int --max-signal-count/int?=null -> Signals:
    start-reading --min-ns=min-ns --max-ns=max-ns --max-signal-count=max-signal-count
    result := null
    try:
      result = wait-for-data
    finally:
      if not result: reset
    return result

/**
An RMT channel.

The channel must be configured after construction.

The channel can be configured for either RX or TX.
*/
class Out extends Channel_:
  /**
  Constructs an output channel on the given $pin.

  The $resolution is the frequency of the clock that the RMT controller uses to
    emit the output signal. It ranges from 312500Hz (312.5KHz) to 80000000Hz (80MHz). Signals
    are specified in ticks of this frequency.

  The $memory-blocks parameter specifies how many RMT memory blocks are assigned to this channel.
    Each memory-block has $BYTES-PER-MEMORY-BLOCK bytes. They are in continuous memory and
    there are only a limited number of them. Since each signal is 2 bytes long, the number of
    signals that can be stored in each block is $memory-blocks * $BYTES-PER-MEMORY-BLOCK / 2.
  Generally, output channels don't need extra blocks as interrupts will copy data into
    the buffer when necessary.
  */
  constructor pin/gpio.Pin
      --resolution/int
      --memory-blocks/int=1
      --open-drain/bool=false
      --pull-up/bool=false:
    if not 1 <= memory-blocks: throw "INVALID_ARGUMENT"

    // Each hw symbol is 4 bytes (2 signals).
    hw-symbols := (memory-blocks * BYTES-PER-MEMORY-BLOCK) >> 2
    kind := open-drain ? Channel_.CHANNEL-KIND-OUTPUT-OPEN-DRAIN_ : Channel_.CHANNEL-KIND-OUTPUT_
    resource := rmt-channel-new_ resource-group_ pin.num resolution hw-symbols kind
    if open-drain:
      pin.set-pull --up=pull-up --off=(not pull-up)
    super.from-sub_ resource

  /**
  Transmits the given $signals.

  If $flush is true (the default) waits for the write to finish before returning. In that
    case, if the write operation is aborted (for example with a $with-timeout), then the
    transmission is aborted and the channel is reset.

  The $done-level parameter specifies the level of the pin when the transmission is done.
  */
  write signals/Signals --flush/bool=true --done-level/int=0 -> none:
    loop-count := 0
    started := rmt-transmit_ resource_ signals.bytes_ loop-count done-level
    if not started:
      // Wait for the previous write to finish.
      this.flush
      started = rmt-transmit_ resource_ signals.bytes_ loop-count done-level
      if not started:
        throw "INVALID_STATE"

    if flush:
      finished-flushing := false
      try:
        this.flush
        finished-flushing = true
      finally:
        if not finished-flushing: reset

  /**
  Blocks until a previous $write operation has finished.
  Returns immediately if no $write operation is in process.
  */
  flush -> none:
    while true:
      state_.clear-state WRITE-STATE_
      if rmt-is-transmit-done_ resource_:
        // The transmission is done.
        break
      state_.wait-for-state WRITE-STATE_


READ-STATE_  ::= 1 << 0
WRITE-STATE_ ::= 1 << 1

resource-group_ ::= rmt-init_

rmt-bytes-per-memory-block_:
  #primitive.rmt.bytes-per-memory-block

rmt-init_:
  #primitive.rmt.init

rmt-channel-new_ resource-group pin-num/int resolution/int symbols/int kind/int:
  #primitive.rmt.channel-new

rmt-channel-delete_ resource-group resource:
  #primitive.rmt.channel-delete

rmt-enable_ resource/ByteArray:
  #primitive.rmt.enable

rmt-disable_ resource/ByteArray:
  #primitive.rmt.disable

rmt-transmit_ resource/ByteArray signals-bytes/*/Blob*/ loop-count/int idle-level/int:
  #primitive.rmt.transmit

rmt-is-transmit-done_ resource/ByteArray:
  #primitive.rmt.is-transmit-done

rmt-start-receive_ resource/ByteArray min-ns/int max-ns/int max-bytes/int:
  #primitive.rmt.start-receive

rmt-receive_ resource/ByteArray:
  #primitive.rmt.receive

rmt-apply-carrier_ resource/ByteArray frequency/int duty-cycle/float active-low/bool always-on/bool:
  #primitive.rmt.apply-carrier
