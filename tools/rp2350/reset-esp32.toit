// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import gpio
import .wiring as wiring

// Reset into the normal application without asserting BOOT.
main:
  run := gpio.Pin wiring.RUN-PIN --output --open-drain --value=1
  try:
    run.set 0
    sleep --ms=100
    run.set 1
    print "rp2350: RUN released"
  finally:
    run.set 1
    run.close
