// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// TODO(floitsch): upstream this into the toit-watchdog package
// (https://github.com/toitware/toit-watchdog) so the portable watchdog API
// works on the EC618 too, instead of relying on this chip-specific library.

/**
The EC618 hardware watchdog.

The watchdog is a hardware timer that resets the device if the application
  stops feeding it. Use it to recover automatically from a hang: arm it with
  $watchdog-start, then call $watchdog-feed regularly from the code path you
  want to keep alive. If the timeout passes without a feed, the device resets.

There is a single hardware watchdog, so these are top-level functions rather
  than objects: arming it twice without stopping in between has no effect
  beyond the first call.

# The reset reads as a power-on

The EC618 has no application-side watchdog interrupt, so the watchdog reset is
  an autonomous hardware reset with no chance for software to record why it
  happened. On the next boot it is therefore reported as a power-on reset
  (`RESET-POWER-ON`, via the `ec618` library's `reset-reason`), indistinguishable
  from a real power cycle. If you need to know that *your* watchdog fired,
  record your own breadcrumb (for example in flash or RTC storage) before the
  reset and check it on boot.

# Timing

The timeout is given in whole seconds, 1 to 60. A watchdog that is never fed
  resets the device once the timeout elapses, so feed it at an interval
  comfortably shorter than the timeout to stay safely armed.

# Caveats

Long blocking operations count against the watchdog. A multi-second flash
  erase, a blocking network call, or a busy loop that never returns to your
  feeding code can trip the watchdog. Either feed from a separate task or
  pick a timeout that comfortably covers the longest operation.

The watchdog clock is gated while the chip is in deep sleep, so the timer
  does not advance there; arrange your feeding around wake-ups accordingly.

# Example

```
import ec618.watchdog

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

/** The shortest watchdog timeout the hardware supports. */
WATCHDOG-MIN-TIMEOUT ::= Duration --s=1
/** The longest watchdog timeout the hardware supports. */
WATCHDOG-MAX-TIMEOUT ::= Duration --s=60

/**
Arms the hardware watchdog with the given $timeout.

The $timeout must be between $WATCHDOG-MIN-TIMEOUT and $WATCHDOG-MAX-TIMEOUT
  and is rounded down to whole seconds. After this call the device resets
  unless $watchdog-feed is called within the $timeout.

To change the timeout, call $watchdog-stop first and then arm again.
*/
watchdog-start --timeout/Duration -> none:
  seconds := timeout.in-s
  if seconds < 1 or seconds > 60: throw "INVALID_ARGUMENT"
  watchdog-init_ seconds

/**
Feeds the watchdog, restarting its timeout.

Has no effect if the watchdog is not armed.
*/
watchdog-feed -> none:
  #primitive.ec618.watchdog-feed

/**
Stops and disables the watchdog.

After this call the watchdog no longer resets the device. Has no effect if
  the watchdog is not armed.
*/
watchdog-stop -> none:
  #primitive.ec618.watchdog-deinit

watchdog-init_ seconds/int -> none:
  #primitive.ec618.watchdog-init
