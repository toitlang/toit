// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
RP2350 chip-specific functionality.

Peripheral APIs use numeric GPIO identifiers: GP4 is pin number 4, regardless
  of its position on the board's header. The RP2350A exposes GP0 through GP29;
  the RP2350B exposes GP0 through GP47. Board connections may reserve some of
  these pins for flash, PSRAM, or other hardware.
*/

import system.firmware  // For toitdoc.

/**
Returns the chip's unique 64-bit identifier as a fresh eight-byte array.

The identifier comes from OTP memory and survives firmware updates and flash
  erasure. Its byte order matches the Pico SDK's board identifier and the USB
  serial number when formatted as hexadecimal.
*/
unique-id -> ByteArray:
  #primitive.rp2350.unique-id

/**
Resets the RP2350 and does not return.

Stops all containers and releases their native resources before rebooting.
  A reset before the running firmware has been validated rejects that trial
  and lets the boot ROM select the previous confirmed firmware.
*/
reset -> none:
  __reset__

/** The shortest duration supported by $deep-sleep. */
DEEP-SLEEP-MIN-DURATION ::= Duration --s=1

/**
Enters deep sleep for $duration and does not return.

Stops all containers, releases their resources, and powers down the processors
  and unused RAM banks. The always-on timer restarts the firmware after sleeping.
  RAM storage buckets, the monotonic clock, and the system time survive deep
  sleep. GPIO configuration and the application watchdog are not retained.
  Flash storage is preserved across both sleep and ordinary resets.

Durations shorter than $DEEP-SLEEP-MIN-DURATION are increased to that duration.
  Timing uses the calibrated low-power oscillator and is approximate. Startup
  and resource teardown take additional time.

Throws `INVALID_STATE` during an unvalidated firmware trial. Complete startup
  checks and call $firmware.validate before sleeping. Use $reset to reject a
  trial and return to the previous firmware.
*/
deep-sleep duration/Duration -> none:
  if is-trial_: throw "INVALID_STATE"
  __deep-sleep__ duration.in-ms

/**
Reports whether this boot followed a deep-sleep power-down.

A subsequent software reset, watchdog expiration, or RUN reset returns false.
*/
woke-from-deep-sleep -> bool:
  #primitive.rp2350.woke-from-deep-sleep

is-trial_ -> bool:
  #primitive.rp2350.is-trial
