// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import gpio

// Requires the board-specific updater: GP17 on W-2023, GP1 on official Pico W.
// Do not use with the original GP1 loader on W-2023. BOOTSEL is unwired.
// Both controls are open drain: release high, never drive against another pin.
main:
  rx := gpio.Pin 4 --output --open-drain --value=1
  try:
    run := gpio.Pin 21 --output --open-drain --value=1
    try:
      rx.set 0
      run.set 0
      sleep --ms=100
      run.set 1
      sleep --ms=1000
    finally:
      run.set 1
      run.close
  finally:
    rx.set 1
    rx.close
  print "Pico W: recovery requested over UART RX and RUN"
