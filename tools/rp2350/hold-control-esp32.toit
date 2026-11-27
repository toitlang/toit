// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.

// Holds the target in reset with BOOT asserted for voltage measurements.
// Both outputs release automatically after five minutes.
import gpio
import .wiring as wiring

main:
  run := gpio.Pin wiring.RUN-PIN --output --open-drain --value=1
  try:
    boot := gpio.Pin wiring.BOOT-PIN --output --open-drain --value=1
    try:
      boot.set 0
      sleep --ms=100
      run.set 0
      print "rp2350: RUN and BOOT held low for five minutes; measure now"
      sleep --ms=300_000
      run.set 1
      sleep --ms=1_000
    finally:
      boot.set 1
      boot.close
  finally:
    run.set 1
    run.close
  print "rp2350: RUN and BOOT released"
