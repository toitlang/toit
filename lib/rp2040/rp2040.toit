// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
RP2040 board-specific functionality.

Peripheral APIs use chip GPIO numbers, independent of their physical header
  positions. Board connections reserve some GPIOs for supply circuitry or radios.
*/

/**
Returns the board's unique identifier as a fresh eight-byte array.

The RP2040 has no unique chip identifier. This identifier comes from the
  external flash chip and survives firmware updates and flash erasure. Its
  byte order matches the Pico SDK's board identifier and the USB serial number
  when formatted as hexadecimal. Replacing the flash chip changes the identity.
*/
unique-id -> ByteArray:
  #primitive.rp2040.unique-id

/**
Resets the RP2040 and does not return.

Stops all containers and releases their native resources before rebooting
  the installed firmware. Persistent flash storage survives the reset.
*/
reset -> none:
  __reset__

/**
Sets the software wall clock to $time.

The new time is immediately visible through $Time.now and is used for TLS
  certificate validity checks. Initialize it from a trusted source before
  opening TLS connections. It starts at the Unix epoch after every reset;
  this target has no battery-backed clock or automatic time synchronization.
The monotonic clock is unaffected.
*/
set-real-time-clock time/Time -> none:
  set-real-time-clock_ time.s-since-epoch time.ns-part

set-real-time-clock_ seconds/int ns/int -> none:
  #primitive.core.set-real-time-clock
