// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.native as native
import system

// Requires the isolated TOIT_BLE_HCI_TESTING build. No RF peer is needed.
main: run

run --disabled/bool=false:
  with-timeout --ms=30_000:
    if disabled:
      radio := esp32.Esp32Transport
      controller := hci.Controller radio
      try:
        hci.initialize controller
        [false, true].do: | deinitialize/bool |
          error := catch: native.testing-stop-controller radio --deinitialize=deinitialize
          if error != "UNIMPLEMENTED": throw "CLOSE_TEST_HOOK_ENABLED"
      finally:
        controller.close
        controller.wait-closed
      print "VHCI_CLOSE_FAILURE DISABLED actions=2"
      return
    [false, true].do: | deinitialize/bool |
      radio := esp32.Esp32Transport
      controller := hci.Controller radio
      try:
        info := hci.initialize controller
        address := info.address.copy
        native.testing-stop-controller radio --deinitialize=deinitialize
        error := catch: controller.close
        if error != "HARDWARE_ERROR": throw "CLOSE_FAILURE_NOT_REPORTED $error"
        controller.wait-closed
        if controller.close-error != error: throw "CLOSE_FAILURE_NOT_RETAINED"
        // The cleared native proxy must never be used by a retry/finalizer.
        controller.close
        radio.close
        system.process-stats --gc
        if controller.close-error != error: throw "CLOSE_FAILURE_LOST"
        print "VHCI_CLOSE_FAILURE ERROR deinit=$deinitialize error=$error retained=true joined=true"
        // This controlled fault leaves the real SDK idle. Reopen is explicit
        // test evidence, never inferred from an idempotent second close.
        recovered := hci.Controller (esp32.Esp32Transport)
        try:
          next := hci.initialize recovered
          if next.address != address: throw "CLOSE_RECOVERY_WRONG_CONTROLLER"
        finally:
          recovered.close
          recovered.wait-closed
        if recovered.close-error: throw recovered.close-error
        print "VHCI_CLOSE_FAILURE RECOVERED deinit=$deinitialize identity=true"
      finally:
        critical-do --no-respect-deadline:
          catch: controller.close
          controller.wait-closed
    print "VHCI_CLOSE_FAILURE COMPLETE failures=2 recovered=2"
