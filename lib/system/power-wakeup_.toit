// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/** A snapshot of a configured wake source. */
abstract class WakeupSource:

/** GPIO wake configuration, or an original ESP32 all-low group. */
class PinWakeup extends WakeupSource:
  /** GPIO numbers, using the same numbering as gpio.Pin. */
  pins/List
  /** Effective trigger: system.power.WAKE-LEVEL or system.power.WAKE-EDGE. */
  trigger/int
  /** True for high/rising, false for low/falling, null for both edges. */
  wake-high/bool?
  /** True when every pin in the group must be low to wake the device. */
  all-low/bool
  /** Whether the internal pull-up is selected for sleep. */
  pull-up/bool
  /** Whether the internal pull-down is selected for sleep. */
  pull-down/bool

  constructor.private_ .pins .trigger .wake-high .all-low .pull-up .pull-down:

  stringify -> string:
    return "GPIO $pins trigger=$(trigger == 1 ? "level" : "edge") wake-high=$wake-high all-low=$all-low pull-up=$pull-up pull-down=$pull-down"

/** A dedicated wake input without an ordinary GPIO number. */
class InputWakeup extends WakeupSource:
  /** Hardware wake-input index; currently EC618 inputs 0 through 2. */
  input/int
  /** Effective trigger: system.power.WAKE-EDGE on EC618. */
  trigger/int
  /** True for rising, false for falling, null for both edges. */
  wake-high/bool?
  /** Whether the wake-input domain's pull-up is selected. */
  pull-up/bool
  /** Whether the wake-input domain's pull-down is selected. */
  pull-down/bool

  constructor.private_ .input .trigger .wake-high .pull-up .pull-down:

  stringify -> string:
    return "wake input $input trigger=edge wake-high=$wake-high pull-up=$pull-up pull-down=$pull-down"

/**
Enabled touch-controller wake.

Touch electrodes and thresholds are configured through the touch library;
  this entry reports whether touch has been enabled as a wake source.
*/
class TouchWakeup extends WakeupSource:
  constructor.private_:

  stringify -> string:
    return "touch wake"

// Internal wire format from src/power.h: kind, identifier, flags per record.
decode-wakeup-sources bytes/ByteArray -> List:
  if bytes.size % 3 != 0: throw "INVALID_ARGUMENT"
  result := []
  all-low-pins := []
  for offset := 0; offset < bytes.size; offset += 3:
    kind := bytes[offset]
    id := bytes[offset + 1]
    flags := bytes[offset + 2]
    trigger := (flags >> 4) & 3
    high/bool? := flags & 64 != 0 ? null : (flags & 1 != 0)
    pull-up := flags & 2 != 0
    pull-down := flags & 4 != 0
    if kind == 0:
      if flags & 128 != 0:
        all-low-pins.add id
      else:
        result.add (PinWakeup.private_ [id] trigger high false pull-up pull-down)
    else if kind == 1:
      result.add (InputWakeup.private_ id trigger high pull-up pull-down)
    else if kind == 2:
      result.add (TouchWakeup.private_)
    else:
      throw "INVALID_ARGUMENT"
  if not all-low-pins.is-empty:
    // The legacy all-low mask has one polarity and no configured pulls.
    result.add (PinWakeup.private_ all-low-pins 1 false true false false)
  return result
