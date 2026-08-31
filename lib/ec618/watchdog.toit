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
The EC618 watchdog.

The watchdog resets the device if the application stops feeding it. Use it to
  recover automatically from a hang: arm it with $watchdog-start, then call
  $watchdog-feed regularly from the code path you want to keep alive. If the
  timeout passes without a feed, the device resets.

There is a single watchdog, so these are top-level functions rather than
  objects: arming it twice without stopping in between just updates the
  deadline.

# How it works (and why it is a software watchdog)

Neither of the EC618's hardware watchdogs can guard the application: the WDT
  module's clock is gated whenever the chip idles (it counts only CPU-active
  time), and the always-on (AON) watchdog belongs to the platform — the modem
  core auto-feeds it. So the timeout is enforced by a small high-priority
  RTOS task, independent of the Toit scheduler: it survives a wedged VM and
  its timed waits wake the chip from light sleep, so the timeout is honored
  in wall-clock time — idle, sleeping, or busy.

The task also keeps the WDT module armed as a hardware backstop: a hang so
  hard that even the watchdog task is starved (an interrupt-off spin, an
  interrupt storm) accumulates CPU-active time on the unfed WDT and triggers
  a hardware reset within roughly 10-20 s.

A Toit `sleep` does NOT stop the watchdog. If you sleep past the timeout
  without feeding, the device resets — feed around long waits, or stop the
  watchdog first. (Deep sleep is different: entering hibernate tears the VM
  down, and waking from it is a fresh boot.)

# Timing

The timeout is given in whole seconds, 1 to 60, and is honored in wall-clock
  time. Detection granularity is a few seconds at most, so feed at an
  interval comfortably shorter than the timeout.

# The reset

A software-watchdog reset prints
  `[toit] FATAL: watchdog timeout (...) — resetting` before resetting, so the
  cause is visible on the console. On the next boot the reset is reported as
  a power-on reset (`RESET-POWER-ON`, via the `ec618` library's
  `reset-reason`); if you need a durable record that *your* watchdog fired,
  write your own breadcrumb (for example in flash) before relying on the
  reset reason.

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

/** The shortest timeout accepted by $watchdog-start. */
WATCHDOG-MIN-TIMEOUT ::= Duration --s=1
/** The longest timeout accepted by $watchdog-start. */
WATCHDOG-MAX-TIMEOUT ::= Duration --s=60

/**
Arms the watchdog with the given $timeout.

The $timeout must be between $WATCHDOG-MIN-TIMEOUT and $WATCHDOG-MAX-TIMEOUT
  and is rounded down to whole seconds. After this call the device resets
  unless $watchdog-feed is called within the $timeout (wall-clock time,
  including light sleep).

Calling this while armed re-arms with the new $timeout.
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
Stops the watchdog.

After this call the watchdog no longer resets the device. Has no effect if
  the watchdog is not armed.
*/
watchdog-stop -> none:
  #primitive.ec618.watchdog-deinit

watchdog-init_ seconds/int -> none:
  #primitive.ec618.watchdog-init
