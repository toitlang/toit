// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.watchdog as watchdog

// Run with lifecycle.py, which verifies that expiration enters recovery.
main:
  [-1, 0, 999, 8001].do: |milliseconds/int|
    expect-throw "INVALID_ARGUMENT":
      watchdog.start --timeout=(Duration --ms=milliseconds)
  watchdog.stop
  watchdog.feed
  sleep --ms=8500
  print "watchdog-rp2040: runtime health PASS"
  watchdog.start --timeout=(Duration --s=8)
  watchdog.start --timeout=(Duration --s=1)
  10.repeat:
    sleep --ms=250
    watchdog.feed
  print "watchdog-rp2040: application feeding PASS"
  watchdog.stop
  watchdog.stop
  // Stopping must return control to the runtime rather than leave an armed
  // but unfed hardware timer behind. Wait beyond both previous timeouts.
  sleep --ms=8500
  print "watchdog-rp2040: application stopped PASS"
  watchdog.start --timeout=(Duration --s=1)
  print "watchdog-rp2040: waiting for expiration"
  sleep --ms=5000
  throw "application watchdog did not expire"
