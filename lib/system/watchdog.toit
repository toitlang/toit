// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

import system.firmware  // For toitdoc.

/**
Controls the device's application watchdog.

The watchdog is shared by all containers. Once started, the device resets if
  the watchdog is not fed before the timeout. Starting it again changes the
  timeout. Calling $feed or $stop while it is stopped has no effect.

Supported timeout ranges depend on the platform. ESP32 supports millisecond
  timeouts, EC618 supports up to 60 seconds with one-second granularity, and
  RP2350 supports 1 through 16 seconds. RP2040 supports 1 through 8 seconds.

On RP2040, the runtime maintains a separate eight-second health deadline while
  the application watchdog is stopped. Starting the application watchdog gives
  it exclusive control of the hardware timer; runtime health checks cannot feed
  it. Stopping the application watchdog restores runtime health monitoring.

On RP2350, an OTA image must call $firmware.validate before $start. Starting
  during the trial period throws `INVALID_STATE`; $feed and $stop leave the
  ROM's trial watchdog unchanged until the application watchdog is armed.
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
