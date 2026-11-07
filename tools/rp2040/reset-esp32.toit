// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import gpio

// Pulse only the verified RUN connection. A USB host can then send "hello"
// during the recovery loader's startup window to keep it in the updater.
main:
  run := gpio.Pin 21 --output --open-drain --value=1
  try:
    run.set 0
    sleep --ms=100
    run.set 1
  finally:
    run.close
  print "RP2040 RUN reset requested"
