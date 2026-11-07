// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.firmware  // For toitdoc.

/**
The RP2350 application watchdog.

There is one hardware watchdog shared by all containers. Once armed, it
  resets the chip if the application stops feeding it, including when the
  VM, scheduler, or interrupts stop making progress. It keeps counting during
  ordinary Toit sleep. Closing or terminating the container that armed it
  does not stop it.

During an OTA trial the boot ROM owns this timer. Complete startup checks
  and call $firmware.validate before calling $watchdog-start. This preserves
  the trial's independent deadline and rollback behavior. Calling
  $watchdog-feed or $watchdog-stop before arming the application watchdog
  leaves the ROM's timer unchanged.
*/

/** The shortest application watchdog timeout. */
WATCHDOG-MIN-TIMEOUT ::= Duration --s=1
/** The longest application watchdog timeout. */
WATCHDOG-MAX-TIMEOUT ::= Duration --s=16

/**
Arms the watchdog, or restarts it with a new $timeout if already armed.

The $timeout must be between $WATCHDOG-MIN-TIMEOUT and
  $WATCHDOG-MAX-TIMEOUT, rounded down to whole milliseconds. Feed at an
  interval comfortably shorter than this timeout.

Throws `INVALID_STATE` if the running firmware has not yet been validated.
  This call does not validate the firmware on the caller's behalf.
*/
watchdog-start --timeout/Duration -> none:
  milliseconds := timeout.in-ms
  if milliseconds < WATCHDOG-MIN-TIMEOUT.in-ms or milliseconds > WATCHDOG-MAX-TIMEOUT.in-ms:
    throw "INVALID_ARGUMENT"
  watchdog-start_ milliseconds

/**
Feeds the application watchdog, restarting its timeout.

Has no effect if the application watchdog is not armed.
*/
watchdog-feed -> none:
  #primitive.rp2350.watchdog-feed

/**
Stops the application watchdog.

Has no effect if it is not armed, including during a firmware trial.
*/
watchdog-stop -> none:
  #primitive.rp2350.watchdog-stop

/**
Reports whether the last boot followed an application watchdog expiration.

Explicit software resets, OTA reboots, and native panic recovery do not count
  as an application watchdog expiration. The result is captured at boot and
  is unaffected by subsequently arming or stopping the watchdog.
*/
caused-reset -> bool:
  #primitive.rp2350.watchdog-caused-reset

watchdog-start_ milliseconds/int -> none:
  #primitive.rp2350.watchdog-start
