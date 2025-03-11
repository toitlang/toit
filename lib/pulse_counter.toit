// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio

/**
Support for the ESP32 pulse counter (PCNT).

Each unit has two channels that can be configured independently. They share the
  same counter.

The ESP32 has 8 units.
The ESP32C3 has no pulse counter.
The ESP32C6 has 4 units.
The ESP32S2 has 4 units.
The ESP32S3 has 4 units.

# Example
```
import pulse-counter
import gpio

main:
  pin := gpio.Pin 18
  unit := pulse-counter.Unit pin
  while true:
    print unit.value
    sleep --ms=500
```
*/

/**
A pulse-counter channel.
*/
class Channel:
  /** The channel does nothing, when the edge change occurs. */
  static EDGE-HOLD /int ::= 0
  /** The channel increments the $Unit.value when the edge change occurs. */
  static EDGE-INCREMENT /int ::= 1
  /** The channel decrements the $Unit.value when the edge change occurs. */
  static EDGE-DECREMENT /int ::= 2

  /** The control pin does not affect the mode of operation for the selected state. */
  static CONTROL-KEEP /int ::= 0
  /**
  The control pin inverses the effect of the mode of operation.
  If the channel's pin was incrementing on an edge, it now decrements. If it was
    decrementing it now increments.
  */
  static CONTROL-INVERSE /int ::= 1
  /**
  The control pin holds the value of the channel.
  No changes to the $Unit.value happen when this control mode is active.
  */
  static CONTROL-HOLD /int ::= 2

  pin/gpio.Pin
  on-positive-edge/int
  on-negative-edge/int
  control-pin/gpio.Pin?
  when-control-low/int
  when-control-high/int

  constructor .pin/gpio.Pin
      --.on-positive-edge /int = EDGE-INCREMENT
      --.on-negative-edge /int = EDGE-HOLD
      --.control-pin /gpio.Pin? = null
      --.when-control-low /int = CONTROL-KEEP
      --.when-control-high /int = CONTROL-KEEP:
    check-edge-mode_ on-positive-edge
    check-edge-mode_ on-negative-edge
    check-control-mode_ when-control-low
    check-control-mode_ when-control-high

  static check-edge-mode_ edge-mode/int -> none:
    if not (EDGE-HOLD <= edge-mode <= EDGE-DECREMENT): throw "INVALID_ARGUMENT"

  static check-control-mode_ control-mode/int -> none:
    if not (CONTROL-KEEP <= control-mode <= CONTROL-HOLD): throw "INVALID_ARGUMENT"


/**
A pulse-counter unit.

The unit shares a counter that is changed by its channels.
*/
class Unit:
  static STATE_STOPPED_ ::= 0
  static STATE_STARTED_ ::= 1
  static STATE_CLOSED_  ::= 2

  unit-resource_ /ByteArray? := ?
  state_ /int := STATE_STOPPED_

  /**
  Variant of $(constructor --channels) that creates a unit with a single channel.
  */
  constructor pin/gpio.Pin
      --on-positive-edge /int = Channel.EDGE-INCREMENT
      --on-negative-edge /int = Channel.EDGE-HOLD
      --control-pin /gpio.Pin? = null
      --when-control-low /int = Channel.CONTROL-KEEP
      --when-control-high /int = Channel.CONTROL-KEEP
      --low/int?=null
      --high/int?=null
      --glitch-filter-ns/int?=null
      --start/bool=true:
    channel := Channel pin
        --on-positive-edge=on-positive-edge
        --on-negative-edge=on-negative-edge
        --control-pin=control-pin
        --when-control-low=when-control-low
        --when-control-high=when-control-high
    return Unit
        --channels=[channel]
        --low=low
        --high=high
        --glitch-filter-ns=glitch-filter-ns
        --start=start

  /**
  Constructs a pulse-counter unit.

  $channels must be a list of $Channel instances.

  The $low and $high values are limits. When the counter reaches this limit, the value
    is reset to 0. Use null to use the maximum range (typically 16 bits).

  If a $glitch-filter-ns is given, then all pulses shorter than $glitch-filter-ns nanoseconds are
    ignored.

  If $start is true (the default), then the unit starts counting immediately.

  # Advanced
  The $glitch-filter-ns are converted to APB clock cycles. Usually the APB clock runs at 80MHz,
    which means that the shortest $glitch-filter-ns that makes sense is 1/80MHz = 12.5ns (-> 13).

  The glitch filter is limited to 10 bits, and the highest value is thus 1023 ticks, or 12_787ns
    (12.5 * 1023 = 12_787.5).
  */
  constructor
      --channels/List
      --low/int?=null
      --high/int?=null
      --glitch-filter-ns/int?=null
      --start/bool=true:
    if glitch-filter-ns != null:
      if glitch-filter-ns <= 0: throw "INVALID_ARGUMENT"
      // The glitch filter runs on the APB clock (80MHz, 12.5ns), and allows at most 1023 ticks.
      // 12.5 * 1023 == 12787.5.
      if glitch-filter-ns > 12_787: throw "OUT_OF_RANGE"
    else:
      glitch-filter-ns = 0
    if low and low >= 0: throw "INVALID_ARGUMENT"
    if high and high <= 0: throw "INVALID_ARGUMENT"
    if not low: low = 0
    if not high: high = 0
    unit-resource_ = pcnt-new-unit_ resource-freeing-module_ low high glitch-filter-ns
    add-finalizer this:: close
    channels.do: | channel/Channel |
      control-pin-num := channel.control-pin ? channel.control-pin.num : -1
      pcnt-new-channel_ unit-resource_ channel.pin.num \
          channel.on-positive-edge channel.on-negative-edge \
          control-pin-num channel.when-control-low channel.when-control-high
    if start: this.start

  /** Whether this unit is closed. */
  is-closed -> bool:
    return state_ == STATE_CLOSED_

  /** Whether this unit is started. */
  is-started -> bool:
    return state_ == STATE_STARTED_

  /**
  Closes this unit.

  Frees all the underlying resources.
  */
  close:
    if is-closed: return
    state_ = STATE_CLOSED_
    remove-finalizer this
    unit-resource := unit-resource_
    unit-resource_ = null
    pcnt-close-unit_ unit-resource

  /**
  The value of the counter.

  The ESP32 hardware supports up to 16 bits, but the range can be limited by providing
    `high` and `low` values to the constructor.

  The unit must not be closed.
  */
  value -> int:
    if is-closed: throw "ALREADY_CLOSED"
    return pcnt-get-count_ unit-resource_

  /**
  Resets the counter to 0.
  */
  clear -> none:
    if is-closed: throw "ALREADY_CLOSED"
    pcnt-clear_ unit-resource_

  /**
  Resumes the counter.

  It is safe to call this method multiple times.

  The unit must not be closed.
  */
  start -> none:
    if is-closed: throw "ALREADY_CLOSED"
    if is-started: return
    pcnt-start_ unit-resource_
    state_ = STATE_STARTED_

  /**
  Pauses the counter.

  It is safe to call this method multiple times.

  The value of the unit is unaffected by this method.

  The unit must not be closed.
  */
  stop -> none:
    if is-closed: throw "ALREADY_CLOSED"
    if not is-started: return
    pcnt-stop_ unit-resource_
    state_ = STATE_STOPPED_

pcnt-new-unit_ resource-group low high glitch-filter-ns:
  #primitive.pcnt.new-unit

pcnt-close-unit_ unit:
  #primitive.pcnt.close-unit

pcnt-new-channel_ unit pin on-positive-edge on-negative-edge control-pin when-control-low when-control-high:
  #primitive.pcnt.new-channel

pcnt-get-count_ unit -> int:
  #primitive.pcnt.get-count

pcnt-clear_ unit -> none:
  #primitive.pcnt.clear

pcnt-start_ unit -> none:
  #primitive.pcnt.start

pcnt-stop_ unit -> none:
  #primitive.pcnt.stop
