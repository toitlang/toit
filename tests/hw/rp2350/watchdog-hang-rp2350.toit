// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import rp2350.watchdog

/**
Runs in an auto-validated bring-up image with TEST_FAULT=watchdog-hang.

The native injector disables interrupts and spins after three seconds. This
  task feeds until that happens; a hardware reset must then recover the VM.
*/

main:
  if watchdog.caused-reset:
    print "watchdog-hang-rp2350: PASS recovered from native interrupt-off hang"
    return
  watchdog.watchdog-start --timeout=(Duration --s=1)
  print "watchdog-hang-rp2350: feeder armed"
  while true:
    watchdog.watchdog-feed
    sleep --ms=100
