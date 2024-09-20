// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import io show LITTLE-ENDIAN

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
  channel := rmt.Channel pin --output --idle-level=0
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
*/
class Signals:
  /** Bytes per ESP32 signal. */
  static BYTES-PER-SIGNAL ::= 2

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

  pin       /gpio.Pin
  resource_ /ByteArray? := ?

  static CONFIGURED-NONE_ ::= 0
  static CONFIGURED-AS-INPUT_ ::= 1
  static CONFIGURED-AS-OUTPUT_ ::= 2
  configured_ /int := CONFIGURED-NONE_

  /** Whether the channel has started reading with $start-reading. */
  is-reading_ /bool := false

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
    resource_ = rmt-channel-new_ resource-group_ memory-block-count (channel-id or -1) 0

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

    resource_ = rmt-channel-new_ resource-group_ memory-block-count (channel-id or -1) -1
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

    resource_ = rmt-channel-new_ resource-group_ memory-block-count (channel-id or -1) 1
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
    if not resource_: throw "ALREADY_CLOSED"
    if not 1 <= clk-div <= 0xFF: throw "INVALID_ARGUMENT"
    if not 1 <= idle-threshold <=0x7FFF: throw "INVALID_ARGUMENT"
    if enable-filter and not 0 <= filter-ticks-threshold <= 0xFF: throw "INVALID_ARGUMENT"
    if buffer-size and buffer-size < 1: throw "INVALID_ARGUMENT"

    rmt-config-rx_ resource_ pin.num clk-div flags idle-threshold enable-filter filter-ticks-threshold (buffer-size or -1)
    configured_ = CONFIGURED-AS-INPUT_

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
    if not resource_: throw "ALREADY_CLOSED"
    if not 1 <= clk-div <= 255: throw "INVALID_ARGUMENT"
    if idle-level != null and idle-level != 0 and idle-level != 1: throw "INVALID_ARGUMENT"
    if enable-carrier:
      if carrier-frequency-hz < 1: throw "INVALID_ARGUMENT"
      if not 1 <= carrier-duty-percent <= 100: throw "INVALID_ARGUMENT"
      if carrier-level != 0 and carrier-level != 1: throw "INVALID_ARGUMENT"

    enable-idle-output := idle-level ? true : false
    idle-level = idle-level or -1
    enable-loop := false
    rmt-config-tx_ resource_ pin.num clk-div flags enable-carrier carrier-frequency-hz carrier-level carrier-duty-percent enable-loop enable-idle-output idle-level
    configured_ = CONFIGURED-AS-OUTPUT_

  /**
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
    if not in.is-input or not out.is-output: throw "INVALID_STATE"
    if in.pin.num != out.pin.num: throw "INVALID_ARGUMENT"
    rmt-config-bidirectional-pin_ out.pin.num out.resource_ pull-up

  is-configured -> bool:
    return configured_ != CONFIGURED-NONE_

  is-input -> bool:
    return configured_ == CONFIGURED-AS-INPUT_

  is-output -> bool:
    return configured_ == CONFIGURED-AS-OUTPUT_

  idle-threshold -> int?:
    return rmt-get-idle-threshold_ resource_

  idle-threshold= threshold/int -> none:
    if not 1 <= threshold <=0x7FFF: throw "INVALID_ARGUMENT"
    rmt-set-idle-threshold_ resource_ threshold

  is-reading -> bool:
    return is-reading_

  /**
  Starts receiving signals for this channel.

  This channel must be configured for receiving (see $(configure --input)).

  If $flush is set (the default) flushes all buffered signals.
  */
  start-reading --flush/bool=true -> none:
    if not is-input: throw "INVALID_STATE"
    is-reading_ = true
    rmt-start-receive_ resource_ flush

  /**
  Stops receiving.
  */
  stop-reading -> none:
    is-reading_ = false
    rmt-stop-receive_ resource_

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

    was-reading := is-reading_
    if stop-reading == null: stop-reading = not was-reading
    if not was-reading: start-reading

    // Increase sleep time over time.
    // TODO(florian): switch to an event-based model.
    // Note that reading could take at worst almost a minute:
    // If the channel uses all 8 memory blocks, it can receive 8 * 64 signals.
    // Each signal can count 2^15 ticks. If the clock (80MHz) is furthermore divided
    // by 255 (the max), then reading can take a long time...
    sleep-time := 1
    try:
      // Let the system prepare a buffer we will use to write the received data into.
      bytes := rmt-prepare-receive_ resource_
      while true:
        result := rmt-receive_ resource_ bytes true
        if result: return Signals.from-bytes result
        sleep --ms=sleep-time
        if sleep-time < 10: sleep-time++
        else if sleep-time < 100: sleep-time *= 2
    finally:
      if stop-reading: this.stop-reading

  /**
  Transmits the given $signals.

  This channel must be configured for writing (see $(configure --output)).
  */
  write signals/Signals -> none:
    if not is-output: throw "INVALID_STATE"

    // Start sending the data.
    // We receive a write-buffer with external memory that we need to keep alive
    // until the sending is done. This buffer may be the $signals.bytes_ buffer
    // if that one is external.
    buffer := rmt-transmit_ resource_ signals.bytes_

    // Increase sleep time over time.
    // TODO(florian): switch to an event-based model.
    // Note that the signal size is not limited, and that writing
    //   the signals can take significant time.
    sleep-time := 1
    // Send the buffer, to ensure that the compiler doesn't optimize the local variable away.
    while not rmt-transmit-done_ resource_ buffer:
      sleep --ms=sleep-time
      if sleep-time < 10: sleep-time++
      else if sleep-time < 100: sleep-time *= 2

  // TODO(florian): add a `write --loop`.
  // This function can only take a limited amount of memory (contrary to $write).
  // It should copy the data into the internal buffers, and then reconfigure the channel.

  /** Closes the channel. */
  close:
    if resource_:
      rmt-channel-delete_ resource-group_ resource_
      resource_ = null
      configured_ = 0

resource-group_ ::= rmt-init_

rmt-init_:
  #primitive.rmt.init

rmt-channel-new_ resource-group memory-block-count channel-num direction:
  #primitive.rmt.channel-new

rmt-channel-delete_ resource-group resource:
  #primitive.rmt.channel-delete

rmt-config-rx_ resource/ByteArray pin-num/int clk-div/int flags/int
    idle-threshold/int filter-en/bool filter-ticks-thresh/int rx-buffer-size/int:
  #primitive.rmt.config-rx

rmt-config-tx_ resource/ByteArray pin-num/int clk-div/int flags/int
    carrier-en/bool carrier-freq-hz/int carrier-level/int carrier-duty-percent/int
    loop-en/bool idle-output-en/bool idle-level/int:
  #primitive.rmt.config-tx

rmt-set-idle-threshold_ resource/ByteArray threshold/int:
  #primitive.rmt.set-idle-threshold

rmt-get-idle-threshold_ resource/ByteArray -> int:
  #primitive.rmt.get-idle-threshold

rmt-config-bidirectional-pin_ pin/int tx-resource/ByteArray enable-pullup/bool:
  #primitive.rmt.config-bidirectional-pin

rmt-transmit_ resource/ByteArray signals-bytes/*/Blob*/:
  #primitive.rmt.transmit

rmt-transmit-done_ resource/ByteArray signals-bytes/*/Blob*/:
  #primitive.rmt.transmit-done

rmt-start-receive_ resource/ByteArray flush/bool:
  #primitive.rmt.start-receive

rmt-stop-receive_ resource/ByteArray:
  #primitive.rmt.stop-receive

rmt-prepare-receive_ resource/ByteArray -> ByteArray:
  #primitive.rmt.prepare-receive

rmt-receive_ resource/ByteArray target/ByteArray resize/bool:
  #primitive.rmt.receive
