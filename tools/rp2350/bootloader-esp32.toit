// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.

// Runs once on the classic ESP32 helper to enter the WeAct's USB bootloader.
// See docs/rp2350-rig-guide.md for wiring and host-side verification.
import gpio
import .wiring as wiring

main:
  // Open released, without internal pulls. A value of 1 releases open-drain.
  run := gpio.Pin wiring.RUN-PIN --output --open-drain --value=1
  try:
    boot := gpio.Pin wiring.BOOT-PIN --output --open-drain --value=1
    try:
      // Match holding the physical BOOT button before pressing reset.
      // WeAct's onboard 1 kohm resistor isolates the flash chip-select output.
      boot.set 0
      sleep --ms=100
      run.set 0
      sleep --ms=100
      run.set 1
      // Allow the boot ROM to sample BOOTSEL. The host checks USB enumeration.
      sleep --ms=1_000
      boot.set 1
      print "rp2350: BOOT and RUN released; check USB bootloader with picotool info"
    finally:
      boot.set 1
      boot.close
  finally:
    run.set 1
    run.close
