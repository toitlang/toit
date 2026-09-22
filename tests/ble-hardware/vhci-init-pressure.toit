// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import system

// Dedicated board: actual heap exhaustion, with no test hooks or RF peer.
main:
  slots := List 2048
  warm := hci.Controller (esp32.Esp32Transport)
  hci.initialize warm
  warm.close
  warm.wait-closed
  set-max-heap-size_ (64 * 1024)
  with-timeout --ms=90_000:
    16.repeat: | trial/int |
      filled := 0
      failure := catch:
        while filled < slots.size:
          slots[filled] = ByteArray 128 --initial=42
          filled++
      if not ["ALLOCATION_FAILED", "OUT_OF_MEMORY"].contains failure:
        throw "PRESSURE_NOT_REACHED"
      (trial + 1).repeat: slots[filled - 1 - it] = null
      radio/esp32.Esp32Transport? := null
      error := catch: radio = esp32.Esp32Transport
      slots.fill null
      system.process-stats --gc
      if radio: radio.close
      debug "INIT_PRESSURE ATTEMPT trial=$trial filled=$filled error=$error"
      recovered := hci.Controller (esp32.Esp32Transport)
      try:
        hci.initialize recovered
      finally:
        recovered.close
        recovered.wait-closed
      debug "INIT_PRESSURE RECOVERED trial=$trial"
    debug "INIT_PRESSURE COMPLETE trials=16"
