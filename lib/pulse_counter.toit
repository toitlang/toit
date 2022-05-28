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
import pulse_counter
import gpio

main:
  pin := gpio.Pin 18
  unit := pulse_counter.Unit
  channel := unit.add_channel pin
  while true:
    print unit.value
    sleep --ms=500
```
*/

/**
A pulse-counter channel.
*/
class Channel:
  unit_/Unit
  channel_id_/int
  closed_/bool := false

  /**
  Constructs a channel for the $unit using the given given $pin.

  The pin is automatically set to input with a pullup.
  */
  constructor.private_ unit/Unit pin/gpio.Pin \
      on_positive_edge/int on_negative_edge/int \
      control_pin/gpio.Pin? when_control_low/int when_control_high/int:
    check_edge_mode_ on_positive_edge
    check_edge_mode_ on_negative_edge
    check_control_mode_ when_control_low
    check_control_mode_ when_control_high

    unit_ = unit
    control_pin_num := control_pin ? control_pin.num : -1
    channel_id_ = pcnt_new_channel_ unit.unit_resource_ pin.num \
        on_positive_edge on_negative_edge \
        control_pin_num when_control_low when_control_high

  /**
  Closes this channel.

  The resources for the channel are returned and can be used for a different configuration.
  */
  close:
    if closed_: return
    closed_ = true
    pcnt_close_channel_ unit_.unit_resource_ channel_id_

  static check_edge_mode_ edge_mode/int -> none:
    if not (Unit.DO_NOTHING <= edge_mode <= Unit.DECREMENT): throw "INVALID_ARGUMENT"

  static check_control_mode_ control_mode/int -> none:
    if not (Unit.KEEP <= control_mode <= Unit.DISABLE): throw "INVALID_ARGUMENT"

/**
A pulse-counter unit.

The unit shares a counter that is changed by its channels.
*/
class Unit:
  unit_resource_ /ByteArray
  closed_/bool := false

  /** The channel Does nothing, when the edge change occurs. */
  static DO_NOTHING /int ::= 0
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

  If a $glitch_filter_ns is given, then all pulses shorter than $glitch_filter_ns nanoseconds are
    ignored.

  A unit is constructed in a started state. As soon as a channel is added with $add_channel it
    starts counting.

  # Advanced
  The $glitch_filter_ns are converted to APB clock cycles. Usually the APB clock runs at 80MHz,
    which means that the shortest glitch_filter_ns that makes sense is 1/80MHz = 12.5ns (-> 13).

  The glitch filter is limited to 10 bits, and the highest value is thus 1023 ticks, or 12_787ns
    (12.5 * 1023 = 12_787.5).
  */
  constructor --low/int=0 --high/int=0 --glitch_filter_ns/int?=null:
    if glitch_filter_ns != null:
      if glitch_filter_ns <= 0: throw "INVALID_ARGUMENT"
      // The glitch filter runs on the APB clock (80MHz, 12.5ns), and allows at most 1023 ticks.
      // 12.5 * 1023 == 12787.5.
      if glitch_filter_ns > 12_787: throw "OUT_OF_RANGE"
    else:
      glitch_filter_ns = -1
    unit_resource_ = pcnt_new_unit_ resource_group_ low high glitch_filter_ns

  /**
  Adds the channel to this counter.

  The channel listens on the given $pin for changes. The counting mode is determined by
    $on_positive_edge and $on_negative_edge. These parameters must be one of:
  - $DO_NOTHING
  - $INCREMENT
  - $DECREMENT

  The $control_pin can be used to change the mode of operation of the channel. The $when_control_low
    and $when_control_high parameters must be one of:
  - $KEEP: The $control_pin does not affect the mode of operation for the selected state.
  - $REVERSE: The $control_pin reverses the effect of the mode of operation. If the channel's pin
    was incrementing on an edge, it now decrements. If it was decrementing it now increments.
  - $DISABLE: The $control_pin disables the channel. No changes to the unit's $value happen when
    this control mode is active.
  */
  add_channel pin/gpio.Pin -> Channel
      --on_positive_edge /int = INCREMENT
      --on_negative_edge /int = DO_NOTHING
      --control_pin /gpio.Pin? = null
      --when_control_low /int = KEEP
      --when_control_high /int = KEEP:
     return Channel.private_ this pin \
         on_positive_edge on_negative_edge \
         control_pin when_control_low when_control_high

  /**
  Closes this unit.

  Frees all the underlying resources.
  */
  close:
    if closed_: return
    // TODO(florian): do we need to keep track of the channels and close them?
    // The underlying resources are already freed.
    closed_ = true
    pcnt_close_unit_ unit_resource_

  /**
  The value of the counter.

  The ESP32 hardware supports up to 16 bits, but the range can be limited by providing
    `high` and `low` values to the constructor.
  */
  value -> int:
    return pcnt_get_count_ unit_resource_

  /**
  Resets the counter to 0.
  */
  clear -> none:
    pcnt_clear_ unit_resource_

  /**
  Resumes the counter.

  It is safe to call this method multiple times.
  */
  start -> none:
    pcnt_start_ unit_resource_

  /**
  Pauses the counter.

  It is safe to call this method multiple times.

  The value of the unit is unaffected by this method.
  */
  stop -> none:
    pcnt_stop_ unit_resource_

resource_group_ ::= pcnt_init_

pcnt_init_:
  #primitive.pcnt.init

pcnt_new_unit_ resource_group low high glitch_filter_ns:
  #primitive.pcnt.new_unit

pcnt_close_unit_ unit:
  #primitive.pcnt.close_unit

pcnt_new_channel_ unit pin on_positive_edge on_negative_edge control_pin when_control_low when_control_high:
  #primitive.pcnt.new_channel

pcnt_close_channel_ unit channel:
  #primitive.pcnt.close_channel

pcnt_get_count_ unit -> int:
  #primitive.pcnt.get_count

pcnt_clear_ unit -> none:
  #primitive.pcnt.clear

pcnt_start_ unit -> none:
  #primitive.pcnt.start

pcnt_stop_ unit -> none:
  #primitive.pcnt.stop
