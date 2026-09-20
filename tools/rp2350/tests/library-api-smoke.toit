// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import rp2350
import rp2350.watchdog

main:
  identifier := rp2350.unique-id
  if identifier.size != 8: throw "unexpected RP2350 identifier size"
  watchdog-reset/bool := watchdog.caused-reset
  print "Application watchdog reset: $watchdog-reset"
  sleep-wakeup/bool := rp2350.woke-from-deep-sleep
  print "Deep sleep wakeup: $sleep-wakeup"
