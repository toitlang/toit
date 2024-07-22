// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio

/**
Support for the ESP32 pulse counter (PCNT).

The ESP32 has up to 8 pulse-counter units, each of which has two channels.
Channels on the same unit share a counter, but can be configured independently otherwise.

# Example
```
import pulse-counter
import gpio

main:
  pin := gpio.Pin 18
  unit := pulse-counter.Unit
  channel := unit.add-channel pin
  while true:
    print unit.value
    sleep --ms=500
```
*/

/**
A pulse-counter channel.
*/
class Channel:
  unit_ /Unit
  // Null if the channel is closed.
  channel-id_ /int? := ?

  /**
  Constructs a channel for the $unit using the given given $pin.

  The pin is automatically set to input with a pullup.
  */
  constructor.private_ unit/Unit pin/gpio.Pin
      on-positive-edge/int on-negative-edge/int
      control-pin/gpio.Pin? when-control-low/int when-control-high/int:
    check-edge-mode_ on-positive-edge
    check-edge-mode_ on-negative-edge
    check-control-mode_ when-control-low
    check-control-mode_ when-control-high

    unit_ = unit
    control-pin-num := control-pin ? control-pin.num : -1
    channel-id_ = pcnt-new-channel_ unit.unit-resource_ pin.num \
        on-positive-edge on-negative-edge \
        control-pin-num when-control-low when-control-high
    add-finalizer this:: close

  /**
  Closes this channel.

  The resources for the channel are returned and can be used for a different configuration.
  */
  close:
    if not channel-id_: return
    remove-finalizer this
    channel-id := channel-id_
    channel-id_ = null
    unit_.remove-channel_ this
    pcnt-close-channel_ unit_.unit-resource_ channel-id

  static check-edge-mode_ edge-mode/int -> none:
    if not (Unit.DO-NOTHING <= edge-mode <= Unit.DECREMENT): throw "INVALID_ARGUMENT"

  static check-control-mode_ control-mode/int -> none:
    if not (Unit.KEEP <= control-mode <= Unit.DISABLE): throw "INVALID_ARGUMENT"

/**
A pulse-counter unit.

The unit shares a counter that is changed by its channels.
*/
class Unit:
  unit-resource_ /ByteArray? := ?
  is-closed_ /bool := false
  channels_ /List ::= []

  /** The channel Does nothing, when the edge change occurs. */
  static DO-NOTHING /int ::= 0
  /** The channel increments the unit's $value when the edge change occurs. */
  static INCREMENT /int ::= 1
  /** The channel decrements the unit's $value when the edge change occurs. */
  static DECREMENT /int ::= 2

  /** The control pin does not affect the mode of operation for the selected state. */
  static KEEP /int ::= 0
  /**
  The control pin reverses the effect of the mode of operation.
  If the channel's pin was incrementing on an edge, it now decrements. If it was
    decrementing it now increments.
  */
  static REVERSE /int ::= 1
  /**
  The control pin disables the channel. No changes to the unit's $value happen when
    this control mode is active.
  */
  static DISABLE /int ::= 2

  /**
  Constructs a pulse-counter unit.

  The $low and $high values are limits. When the counter reaches this limit, the value
    is reset to 0. Use 0 to use the full 16 bit range of the counter.

  If a $glitch-filter-ns is given, then all pulses shorter than $glitch-filter-ns nanoseconds are
    ignored.

  A unit is constructed in a started state. As soon as a channel is added with $add-channel it
    starts counting.

  # Advanced
  The $glitch-filter-ns are converted to APB clock cycles. Usually the APB clock runs at 80MHz,
    which means that the shortest $glitch-filter-ns that makes sense is 1/80MHz = 12.5ns (-> 13).

  The glitch filter is limited to 10 bits, and the highest value is thus 1023 ticks, or 12_787ns
    (12.5 * 1023 = 12_787.5).
  */
  constructor --low/int=0 --high/int=0 --glitch-filter-ns/int?=null:
    if glitch-filter-ns != null:
      if glitch-filter-ns <= 0: throw "INVALID_ARGUMENT"
      // The glitch filter runs on the APB clock (80MHz, 12.5ns), and allows at most 1023 ticks.
      // 12.5 * 1023 == 12787.5.
      if glitch-filter-ns > 12_787: throw "OUT_OF_RANGE"
    else:
      glitch-filter-ns = -1
    unit-resource_ = pcnt-new-unit_ resource-freeing-module_ low high glitch-filter-ns
    add-finalizer this:: close

  /**
  Adds the channel to this counter.

  The channel listens on the given $pin for changes. The counting mode is determined by
    $on-positive-edge and $on-negative-edge. These parameters must be one of:
  - $DO-NOTHING
  - $INCREMENT
  - $DECREMENT

  The $control-pin can be used to change the mode of operation of the channel. The $when-control-low
    and $when-control-high parameters must be one of:
  - $KEEP: The $control-pin does not affect the mode of operation for the selected state.
  - $REVERSE: The $control-pin reverses the effect of the mode of operation. If the channel's pin
    was incrementing on an edge, it now decrements. If it was decrementing it now increments.
  - $DISABLE: The $control-pin disables the channel. No changes to the unit's $value happen when
    this control mode is active.
  */
  add-channel pin/gpio.Pin -> Channel
      --on-positive-edge /int = INCREMENT
      --on-negative-edge /int = DO-NOTHING
      --control-pin /gpio.Pin? = null
      --when-control-low /int = KEEP
      --when-control-high /int = KEEP:
    if is-closed: throw "ALREADY_CLOSED"
    channel := Channel.private_ this pin \
        on-positive-edge on-negative-edge \
        control-pin when-control-low when-control-high
    channels_.add channel
    return channel

  /**
  Removes the channel from the internal list.
  This function must be called by the $Channel when it is closed.
  */
  remove-channel_ channel/Channel -> none:
    channels_.remove channel

  /** Whether this unit is closed. */
  is-closed -> bool:
    return is-closed_

  /**
  Closes this unit.

  Frees all the underlying resources.
  */
  close:
    if is-closed: return
    is-closed_ = true
    remove-finalizer this
    // The $Channel.close method needs the unit resource. Don't clear it
    // before the channels are closed.
    // Make a copy, since the `close` methods will change the channels_ list.
    channels_.copy.do: it.close
    assert: channels_.is-empty
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
    pcnt-start_ unit-resource_

  /**
  Pauses the counter.

  It is safe to call this method multiple times.

  The value of the unit is unaffected by this method.

  The unit must not be closed.
  */
  stop -> none:
    pcnt-stop_ unit-resource_

pcnt-new-unit_ resource-group low high glitch-filter-ns:
  #primitive.pcnt.new-unit

pcnt-close-unit_ unit:
  #primitive.pcnt.close-unit

pcnt-new-channel_ unit pin on-positive-edge on-negative-edge control-pin when-control-low when-control-high:
  #primitive.pcnt.new-channel

pcnt-close-channel_ unit channel:
  #primitive.pcnt.close-channel

pcnt-get-count_ unit -> int:
  #primitive.pcnt.get-count

pcnt-clear_ unit -> none:
  #primitive.pcnt.clear

pcnt-start_ unit -> none:
  #primitive.pcnt.start

pcnt-stop_ unit -> none:
  #primitive.pcnt.stop
