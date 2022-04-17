// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio

/**
Support for the ESP32 pulse counter (PCNT).

The ESP32 has up to 8 pulse-counter units, each of which has two channels.
Channels on the same unit share a counter, but can be configured independently
  otherwise.

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
  constructor.private_ unit/Unit pin/gpio.Pin:
    unit_ = unit
    channel_id_ = pcnt_new_channel_ unit.unit_resource_ pin.num

  /**
  Closes this channel.

  The resources for the channel are returned and can be used for a different configuration.
  */
  close:
    if closed_: return
    closed_ = true
    pcnt_close_channel_ unit_.unit_resource_ channel_id_

/**
A pulse-counter unit.

The unit shares a counter that is changed by its channels.
*/
class Unit:
  unit_resource_ /ByteArray
  closed_/bool := false

  /**
  Constructs a pulse-counter unit.

  The $low and $high values are limits. When the counter reaches this limit, the value
    is reset to 0. Use 0 to use the full 16 bit range of the counter.

  A unit is constructed in a started state. As soon as a channel is added it starts counting.
  */
  constructor --low/int=0 --high/int=0:
    unit_resource_ = pcnt_new_unit_ resource_group_ low high

  /**
  Adds the channel to this counter.
  */
  add_channel pin/gpio.Pin -> Channel:
     return Channel.private_ this pin

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
  TODO(florian): test this.
  */
  start -> none:
    pcnt_start_ unit_resource_

  /**
  Pauses the counter.

  It is safe to call this method multiple times.
  TODO(florian): test this.

  The value of the unit is unaffected by this method.
  */
  stop -> none:
    pcnt_stop_ unit_resource_

resource_group_ ::= pcnt_init_

pcnt_init_:
  #primitive.pcnt.init

pcnt_new_unit_ resource_group low high:
  #primitive.pcnt.new_unit

pcnt_close_unit_ unit:
  #primitive.pcnt.close_unit

pcnt_new_channel_ unit pin:
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
