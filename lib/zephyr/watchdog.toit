// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Application-controlled hardware watchdog for Toit on Zephyr.

The current nRF5340 backend uses application-core WDT0. It resets the device
  when the application stops calling $watchdog-feed. The timer keeps running
  during ordinary CPU sleep and does not depend on Toit tasks or interrupts.
  It pauses while a debugger has halted the CPU.

There is one watchdog shared by all processes. It remains armed when a process
  exits or the VM shuts down, until explicitly stopped or the hardware resets.
  Any process can start, feed, or stop it. The VM scheduler does not feed it
  automatically; feed from the application path whose progress matters.

```
import zephyr.watchdog

main:
  watchdog.watchdog-start --timeout=(Duration --s=10)
  try:
    while true:
      do-work
      watchdog.watchdog-feed
  finally:
    watchdog.watchdog-stop
```
*/

/** The shortest timeout supported by the nRF5340 backend. */
WATCHDOG-MIN-TIMEOUT ::= Duration --ms=1
/** The longest timeout supported by the nRF5340 backend. */
WATCHDOG-MAX-TIMEOUT ::= Duration --ms=0x07cf_ffff

/**
Arms the watchdog with the given $timeout.

The timeout is rounded down to whole milliseconds and must be between
  $WATCHDOG-MIN-TIMEOUT and $WATCHDOG-MAX-TIMEOUT. Starting an already armed
  watchdog stops and reconfigures it, then starts a new timeout period.
  An invalid timeout leaves an existing watchdog unchanged.
*/
watchdog-start --timeout/Duration -> none:
  watchdog-start_ timeout.in-ms

/**
Restarts the watchdog's timeout period.

Has no effect when the watchdog is stopped.
*/
watchdog-feed -> none:
  #primitive.zephyr.watchdog-feed

/**
Stops the watchdog and releases its hardware reload channel.

Has no effect when already stopped. Supported on the nRF5340; other Zephyr
  targets may have watchdog hardware that cannot be stopped once started.
*/
watchdog-stop -> none:
  #primitive.zephyr.watchdog-stop

watchdog-start_ ms/int -> none:
  #primitive.zephyr.watchdog-start
