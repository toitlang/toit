// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import system
import .initialize show Platform
import ....toolchains.rp2350.ota-console show UpdateConsole

main:
  error := catch --trace:
    platform := Platform
    console := UpdateConsole
    system.process-stats --gc
    platform.start-containers
    // As on ESP32/EC618, boot applications confirm the firmware after their
    // own startup checks. A critical application's failure stops the system.
    task::
      result := platform.containers.wait-until-done
      if result != 0: exit result
    console.run
  print "RP2350 system startup failed: $error"
  // The native error path reboots normally, rejecting an unconfirmed trial.
  exit 1
