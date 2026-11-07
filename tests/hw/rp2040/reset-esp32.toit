// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import gpio

// Pico W-2023 fixture: ESP32 GPIO21 -> RUN, GPIO4 -> GP17/recovery.
// Reset the Pico into its application without changing the modem's state.
main:
  recovery := gpio.Pin 4 --input
  recovery.set-pull --up
  run := gpio.Pin 21 --output --open-drain --value=1
  try:
    run.set 0
    sleep --ms=100
    run.set 1
    print "RP2040 helper: RUN released"
  finally:
    run.set 1
    run.close
    recovery.close
