// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

/**
Controls the device's application watchdog.

The watchdog is shared by all containers. Once started, the device resets if
  the watchdog is not fed before the timeout. Starting it again changes the
  timeout. Calling $feed or $stop while it is stopped has no effect.

Supported timeout ranges depend on the platform. ESP32 supports positive
  millisecond timeouts. EC618 accepts 1 through 60000 milliseconds, rounding
  up to whole seconds. On EC618, the deadline task runs independently of the
  Toit scheduler and continues timing during light sleep; deep sleep ends
  monitoring and waking starts a fresh boot.

The platform-specific watchdog APIs operate on this same watchdog. Other
  containers that feed or reconfigure it can interfere with monitoring.
  Host platforms throw `UNIMPLEMENTED`.
*/

/** Starts or restarts the watchdog with the given $timeout. */
start --timeout/Duration -> none:
  milliseconds := timeout.in-ms
  if milliseconds <= 0: throw "INVALID_ARGUMENT"
  start_ milliseconds

/** Feeds the watchdog, restarting its timeout if it is running. */
feed -> none:
  #primitive.watchdog.feed

/** Stops the watchdog. */
stop -> none:
  #primitive.watchdog.stop

start_ timeout-ms/int -> none:
  #primitive.watchdog.start
