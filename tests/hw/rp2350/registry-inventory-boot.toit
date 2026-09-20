// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
// Run as the privileged system snapshot, alongside the healthy boot container.
import system
import ....system.extensions.rp2350.initialize show Platform
import ....system.flash.registry show FlashRegistry
import ....toolchains.rp2350.ota-console show UpdateConsole

main:
  error := catch --trace:
    platform := Platform
    registry := FlashRegistry.scan
    registry.do: | allocation |
      print "registry-inventory: offset=$allocation.offset size=$allocation.size type=$allocation.type id=$allocation.id"
    print "registry-inventory: PASS scan complete"
    console := UpdateConsole
    system.process-stats --gc
    platform.start-containers
    task::
      result := platform.containers.wait-until-done
      if result != 0: exit result
    console.run
  print "registry-inventory: FAIL $error"
  exit 1
