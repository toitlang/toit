// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.controller-states as states
import ble.experimental.esp32
import ble.experimental.hci
import encoding.hex

main:
  controller := hci.Controller (esp32.Esp32Transport)
  try:
    info := hci.initialize controller
    supported := states.read controller
    print "VHCI_STATES address=$(hex.encode info.address.reverse) raw=$(hex.encode supported.bytes)"
    print "VHCI_STATES advertising-with-central=$(supported.supports states.CONNECTABLE-ADVERTISING-WITH-CENTRAL) initiating-with-peripheral=$(supported.supports states.INITIATING-WITH-PERIPHERAL)"
  finally:
    controller.close
    controller.wait-closed
  print "VHCI_STATES COMPLETE"
