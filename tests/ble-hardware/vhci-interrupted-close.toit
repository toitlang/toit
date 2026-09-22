// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import monitor
import system

// Normal controller-only firmware; no test hooks, peer, or bond storage.
main:
  with-timeout --ms=60_000:
    address := identity
    20.repeat: | round/int |
      radio := esp32.Esp32Transport
      try:
        if round % 2 == 0:
          error := catch:
            with-timeout --ms=1:
              try:
                sleep --ms=100
              finally:
                radio.close
          if error != DEADLINE-EXCEEDED-ERROR: throw "UNEXPECTED_DEADLINE_RESULT"
        else:
          entered := monitor.Latch
          ended := monitor.Latch
          blocked := monitor.Latch
          worker := task::
            try:
              entered.set true
              blocked.get
            finally:
              try:
                radio.close
              finally:
                critical-do --no-respect-deadline: ended.set true
          try:
            entered.get
            sleep --ms=1
            worker.cancel
            with-timeout --ms=1_000: ended.get
          finally:
            worker.cancel
        error := catch: radio.send #[1, 3, 12, 0]
        if error != "HCI_CLOSED": throw "INTERRUPTED_CLOSE_NOT_CLOSED"
        // This is the ownership check: a null managed state alone is insufficient.
        if (identity) != address: throw "INTERRUPTED_CLOSE_WRONG_CONTROLLER"
        system.process-stats --gc
        debug "INTERRUPTED_CLOSE ROUND round=$round reopened=true"
      finally:
        radio.close
    debug "INTERRUPTED_CLOSE COMPLETE rounds=20 deadlines=10 cancellations=10"

identity -> ByteArray:
  controller := hci.Controller (esp32.Esp32Transport)
  try:
    return (hci.initialize controller).address.copy
  finally:
    controller.close
    controller.wait-closed
