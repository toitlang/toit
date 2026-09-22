// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import encoding.hex
import system

main:
  20.repeat: | cycle/int |
    controller := hci.Controller (esp32.Esp32Transport)
    try:
      info := hci.initialize controller
      print "VHCI_INFO cycle=$cycle address=$(hex.encode info.address.reverse) acl-length=$(info.acl-length) acl-count=$(info.acl-count)"
      if cycle == 0:
        print "VHCI_INFO version=$(hex.encode info.version) commands=$(hex.encode info.commands)"
        // Core Vol 4 Part E 6.27: octet 10, bits 5, 6 and 7.
        flags := info.commands[10]
        print "VHCI_RX_FLOW set-control=$(flags & 0x20 != 0) host-buffer=$(flags & 0x40 != 0) host-completed=$(flags & 0x80 != 0)"
    finally:
      controller.close
      controller.wait-closed
    system.process-stats --gc
  print "VHCI_INFO COMPLETE cycles=20"
