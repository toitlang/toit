// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.

// Measures the control lines at the ESP32 while attempting BOOTSEL entry.
// Only drives low or releases; never drives the target's flash select high.
import gpio
import .wiring as wiring

main:
  run := gpio.Pin wiring.RUN-PIN --input --output --open-drain --value=1
  try:
    boot := gpio.Pin wiring.BOOT-PIN --input --output --open-drain --value=1
    try:
      boot.set 0
      sleep --ms=500
      print "BOOT held low: RUN=$(run.get), BOOT=$(boot.get)"
      run.set 0
      sleep --ms=500
      print "Both asserted: RUN=$(run.get), BOOT=$(boot.get)"
      run.set 1
      sleep --ms=2_000
      print "RUN released: RUN=$(run.get), BOOT held low=$(boot.get)"
      boot.set 1
      sleep --ms=500
      print "Both released: RUN=$(run.get), BOOT=$(boot.get)"
    finally:
      boot.set 1
      boot.close
  finally:
    run.set 1
    run.close
