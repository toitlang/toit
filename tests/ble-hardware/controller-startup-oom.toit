// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import monitor
import system
import system.containers

// Dedicated board. Child containers deliberately die with native VHCI open.
// No explicit child cleanup, peer, pairing, or persistent storage changes.
main arguments:
  if arguments is Map:
    victim arguments["cycle"]
    throw "EXPECTED_STARTUP_OOM"
  // Serial heap reports during each deliberate failure are substantial.
  with-timeout --ms=240_000:
    print "STARTUP_OOM START cycles=12"
    12.repeat: | cycle/int |
      child := containers.start containers.current {"cycle": cycle}
      try:
        code := child.wait
        if code != 1: throw "EXPECTED_CHILD_FAILURE $code"
        print "STARTUP_OOM DEAD cycle=$cycle exit=$code"
      finally:
        child.close
      radio := esp32.Esp32Transport
      controller := hci.Controller radio
      try:
        sample := radio.diagnostics
        if sample.queued != 0 or sample.fault: throw "REOPEN_DIRTY"
        hci.initialize controller
      finally:
        controller.close
        controller.wait-closed
      stats := system.process-stats --gc
      print "STARTUP_OOM RECOVERED cycle=$cycle free=$(stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY]) largest=$(stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE])"
      // Separate retained process pages from native allocations after cleanup.
      system.serial-print-heap-report "STARTUP_OOM AFTER cycle=$cycle"
    print "STARTUP_OOM COMPLETE cycles=12"

victim cycle/int:
  controller := hci.Controller (esp32.Esp32Transport)
  hci.initialize controller
  slots := List 4096
  timeout := Duration --ms=20
  set-max-heap-size_ (64 * 1024)
  print "STARTUP_OOM OWNED cycle=$cycle heap=65536"
  64.repeat: | trial/int |
    gate := monitor.Latch
    ended := monitor.Latch
    worker := task --background::
      try:
        catch: gate.get
      finally:
        critical-do --no-respect-deadline: ended.set true
    filled := 0
    try:
      failure := catch:
        while filled < slots.size:
          slots[filled] = ByteArray 8 --initial=42
          filled++
      if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
        throw "PRESSURE_NOT_REACHED"
      (trial * 4).repeat: slots[filled - 1 - it] = null
      catch:
        with-timeout timeout: ended.get
      slots.fill null
      system.process-stats --gc
    finally:
      slots.fill null
      worker.cancel
    // Keep the controller reachable until the process fails.
    if controller.close-error: throw "UNEXPECTED_CONTROLLER_CLOSE"
