// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import rp2350.watchdog
import system
import system.firmware

/** Keeps the application watchdog armed while the host uploads another image. */
main:
  system.process-stats --gc
  firmware.validate
  watchdog.watchdog-start --timeout=(Duration --s=4)
  print "watchdog-ota-rp2350: armed; ready for OTA"
  while true:
    watchdog.watchdog-feed
    sleep --ms=100
